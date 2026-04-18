module "karpenter" {
  source = "../../modules/karpenter"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  region            = var.aws_region
  account_id        = data.aws_caller_identity.current.account_id

  karpenter_version = var.karpenter_version
}

# -----------------------------------------------------------------------------
# CPU inference — Karpenter NodePool + EC2NodeClass
#
# Replaces the former cpu_inference managed node group. Selects subnets
# tagged karpenter.sh/discovery = "${cluster}-cpu" (10.0.2x.xx — see vpc.tf)
# and launches AL2023 nodes matching pod requests from KPA-driven workloads.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "karpenter_cpu_nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "cpu"
    }
    spec = {
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      role = module.karpenter.node_iam_role_name

      metadataOptions = {
        httpEndpoint            = "enabled"
        httpTokens              = "required"
        httpPutResponseHopLimit = 2
      }

      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "200Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]

      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = "${var.cluster_name}-cpu" } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      tags = {
        "karpenter.sh/discovery" = var.cluster_name
        "role"                   = "inference"
        "inference/type"         = "cpu"
      }
    }
  })

  depends_on = [module.karpenter]
}

resource "kubectl_manifest" "karpenter_cpu_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "cpu"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            role             = "inference"
            "inference/type" = "cpu"
          }
        }
        spec = {
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = [var.cpu_node_instance_type]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = [var.karpenter_capacity_type]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            }
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "cpu"
          }
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = var.karpenter_consolidate_after
      }
      limits = {
        cpu = var.cpu_node_max * 8 # var.cpu_node_instance_type is m6i.2xlarge = 8 vCPU
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_cpu_nodeclass]
}

# -----------------------------------------------------------------------------
# GPU inference — Karpenter NodePool + EC2NodeClass
#
# Replaces the former gpu_inference managed node group. Uses the Bottlerocket
# NVIDIA variant (drivers + container toolkit baked in), matching the eks-ray
# cluster's setup and the existing gpu_operator.tf assumptions
# (driver.enabled=false, toolkit.enabled=false).
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "karpenter_gpu_nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu"
    }
    spec = {
      amiSelectorTerms = [
        { alias = "bottlerocket@latest" }
      ]
      role = module.karpenter.node_iam_role_name

      metadataOptions = {
        httpEndpoint            = "enabled"
        httpTokens              = "required"
        httpPutResponseHopLimit = 2
      }

      # Bottlerocket splits OS and container storage:
      #   /dev/xvda — OS volume (small, read-only root)
      #   /dev/xvdb — data / containerd volume (image cache)
      # 500Gi matches the eks-ray GPU pool and the former kserve GPU MNG's
      # model-weight caching requirement.
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "4Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        },
        {
          deviceName = "/dev/xvdb"
          ebs = {
            volumeSize          = "500Gi"
            volumeType          = "gp3"
            iops                = 6000
            throughput          = 500
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]

      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = "${var.cluster_name}-gpu" } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      tags = {
        "karpenter.sh/discovery" = var.cluster_name
        "role"                   = "inference"
        "inference/type"         = "gpu"
      }
    }
  })

  depends_on = [module.karpenter]
}

resource "kubectl_manifest" "karpenter_gpu_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            role                     = "inference"
            "inference/type"         = "gpu"
            "nvidia.com/gpu.present" = "true"
          }
        }
        spec = {
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = [var.gpu_node_instance_type]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = [var.karpenter_capacity_type]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            # Restrict to AZs that actually offer the chosen GPU type — e.g.
            # g5 is not offered in ap-southeast-2b. Without this Karpenter
            # attempts launches in the unsupported AZ and enters backoff.
            # sort() pins the order: the data source returns AZs in
            # non-deterministic order, which would otherwise produce a
            # spurious NodePool diff on every plan.
            {
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = sort(data.aws_ec2_instance_type_offerings.gpu.locations)
            }
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu"
          }
          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "true"
              effect = "NoSchedule"
            }
          ]
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = var.karpenter_consolidate_after
      }
      limits = {
        "nvidia.com/gpu" = var.gpu_node_max
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_gpu_nodeclass]
}
