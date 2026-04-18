module "karpenter" {
  count = var.karpenter_enabled ? 1 : 0

  source = "../../modules/karpenter"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  region            = var.region
  account_id        = data.aws_caller_identity.current.account_id

  karpenter_version           = var.karpenter_version
  enable_capacity_reservation = var.karpenter_cr_enabled

  node_iam_role_additional_policies = {
    s3_policy = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  }
}

# GPU EC2NodeClass — Bottlerocket has an official NVIDIA variant that
# Karpenter auto-selects for GPU-labeled instance types via the
# `bottlerocket@latest` alias. Drivers + container toolkit are baked in, so
# the NVIDIA GPU Operator only needs to deploy the device plugin and DCGM
# exporter (driver.enabled=false, toolkit.enabled=false in gpu_operator.tf)
# — matching the kserve cluster's AL2023_x86_64_NVIDIA behaviour.
resource "kubectl_manifest" "karpenter_gpu_nodeclass" {
  count = var.karpenter_enabled ? 1 : 0

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
      role = module.karpenter[0].node_iam_role_name

      # Pods use IRSA (see iam.tf -> ray_serving_irsa); hopLimit=2 is kept
      # so any workload that still falls through to the node IAM role can
      # reach IMDSv2 from inside the pod network namespace.
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpTokens              = "required"
        httpPutResponseHopLimit = 2
      }

      # Bottlerocket uses two EBS volumes:
      #   /dev/xvda — OS volume (small, read-only root)
      #   /dev/xvdb — data / containerd volume (holds pulled images)
      # Default data volume is ~20Gi which is too small for ray-ml/vLLM GPU
      # images and causes kubelet ephemeral-storage eviction during image
      # pull. Bump to 500Gi to match the kserve GPU node group.
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

      # Discovery-tagged only on the 10.0.3x.xx subnets (see vpc.tf).
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      tags = {
        "karpenter.sh/discovery" = var.cluster_name
        "role"                   = "ray"
        "ray.io/purpose"         = "gpu"
      }
    }
  })

  depends_on = [module.karpenter]
}

resource "kubectl_manifest" "karpenter_gpu_provisioner" {
  count = var.karpenter_enabled ? 1 : 0

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
            role                     = "ray"
            "ray.io/purpose"         = "gpu"
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
            # Restrict to AZs that actually offer the chosen GPU type —
            # e.g. g5 is not offered in ap-southeast-2b. Without this
            # Karpenter attempts launches in the unsupported AZ and enters
            # backoff. See data.aws_ec2_instance_type_offerings.gpu.
            # sort() pins the order — the data source returns AZs in
            # non-deterministic order, producing spurious plan diffs.
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
