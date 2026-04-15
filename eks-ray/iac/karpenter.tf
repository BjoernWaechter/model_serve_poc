data "aws_caller_identity" "current" {}

module "karpenter" {
  count = var.karpenter_enabled ? 1 : 0

  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.37.0"

  cluster_name = module.eks.cluster_name

  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  create_iam_role      = true
  create_node_iam_role = true
  enable_irsa          = true
  create_access_entry  = true
  iam_role_name        = "${module.eks.cluster_name}-karpenter-controller"
  node_iam_role_name   = "${module.eks.cluster_name}-karpenter-node"

  node_iam_role_attach_cni_policy = true
  node_iam_role_additional_policies = {
    s3_policy = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  }

  # Capacity reservation support (ODCR and Capacity Blocks for ML)
  iam_policy_statements = var.karpenter_cr_enabled ? [
    {
      sid       = "AllowDescribeCapacityReservations"
      effect    = "Allow"
      actions   = ["ec2:DescribeCapacityReservations"]
      resources = ["*"]
    },
    {
      sid       = "AllowRunInstancesOnCapacityReservation"
      effect    = "Allow"
      actions   = ["ec2:RunInstances", "ec2:CreateFleet"]
      resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:capacity-reservation/*"]
    }
  ] : []

}

# aws-auth ConfigMap is managed by the EKS module itself; Karpenter nodes
# join the cluster via an EKS access entry (create_access_entry = true above),
# so we do NOT create a separate aws-auth ConfigMap here.

resource "helm_release" "karpenter-crd" {
  count = var.karpenter_enabled ? 1 : 0

  name       = "karpenter-crd"
  chart      = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter/"
  version    = var.karpenter_version
  namespace  = "karpenter"
  create_namespace = true
}

resource "helm_release" "karpenter" {
  count = var.karpenter_enabled ? 1 : 0

  name             = "karpenter"
  chart            = "karpenter"
  cleanup_on_fail  = true
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter/"
  version          = var.karpenter_version
  namespace        = "karpenter"
  timeout          = 300
  wait             = true

  values = [
    <<-EOT
      controller:
        resources:
          limits:
            cpu: 1
            memory: 2Gi
          requests:
            cpu: 1
            memory: 2Gi
      settings:
        clusterName: "${module.eks.cluster_name}"
        clusterEndpoint: "${module.eks.cluster_endpoint}"
        interruptionQueue: "${module.karpenter[0].queue_name}"
        featureGates:
          reservedCapacity: ${var.karpenter_cr_enabled}
      serviceAccount:
        annotations:
          eks.amazonaws.com/role-arn: "${module.karpenter[0].iam_role_arn}"
      webhook:
        enabled: false
    EOT
  ]

  depends_on = [helm_release.karpenter-crd, module.cluster_autoscaler]

}

# Note: there is no upstream "karpenter-components" Helm chart. The EC2NodeClass
# and NodePool custom resources below replace that block.

# module "karpenter_iam_role" {
#   source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#   version = "~> 5.0"

#   role_name_prefix                   = "karpenter-controller"
#   attach_karpenter_controller_policy = true

#   oidc_providers = {
#     eks = {
#       provider_arn               = module.eks.oidc_provider_arn
#       namespace_service_accounts = ["karpenter:karpenter"]
#     }
#   }
# }

# resource "aws_sqs_queue" "karpenter" {
#   name = "${module.eks.cluster_name}-karpenter"
# }

# (Removed duplicate helm_release.karpenter_crds — the karpenter-crd chart is
# already installed above as helm_release.karpenter-crd at the pinned version.)

# resource "helm_release" "karpenter" {
#   name       = "karpenter"
#   namespace  = "karpenter"
#   repository = "oci://public.ecr.aws/karpenter"
#   chart      = "karpenter"
#   version    = "1.10.0" # or latest stable

#   create_namespace = true

#   set {
#     name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
#     value = aws_iam_role.karpenter_role.arn
#   }

#   set {
#     name  = "settings.clusterName"
#     value = module.eks.cluster_name
#   }

#   set {
#     name  = "settings.clusterEndpoint"
#     value = module.eks.cluster_endpoint
#   }

#   set {
#     name  = "settings.interruptionQueue"
#     value = aws_sqs_queue.karpenter.name
#   }
#   depends_on = [time_sleep.wait_k8s_ready]
# }


resource "kubectl_manifest" "karpenter_gpu_nodeclass" {
  count = var.karpenter_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu"
    }
    spec = {
      # Bottlerocket has an official NVIDIA variant selected by the @latest alias.
      amiSelectorTerms = [
        {
          alias = "bottlerocket@latest"
        }
      ]
      role = module.karpenter[0].node_iam_role_name
      # Allow pods to reach IMDSv2 so boto3 can fall back to the node IAM
      # role credentials (needed for Ray `working_dir: s3://...` downloads).
      # Default hopLimit is 1 which only serves the host; pods are one hop
      # further and get NoCredentialsError. For a proper prod setup, use
      # IRSA on the Ray pod service account instead.
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpTokens              = "required"
        httpPutResponseHopLimit = 2
      }
      # Bottlerocket uses two EBS volumes:
      #   /dev/xvda - OS volume (small)
      #   /dev/xvdb - data / containerd volume (holds pulled images)
      # The default 20Gi data volume is too small for ray-ml GPU images
      # (~10Gi+ compressed, more uncompressed) and causes kubelet
      # ephemeral-storage eviction during image pull. Bump to 200Gi.
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
            volumeSize          = "200Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
      ]
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
      ]
      tags = {
        "karpenter.sh/discovery" = var.cluster_name
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "karpenter_gpu_provisioner" {
  count = var.karpenter_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu-g4dn"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            workload = "gpu"
          }
        }
        spec = {
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = ["g4dn.xlarge"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
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
      limits = {
        "nvidia.com/gpu" = 4
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_gpu_nodeclass
  ]
}
