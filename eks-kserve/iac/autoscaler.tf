module "cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                        = "${var.cluster_name}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.37.0"
  namespace  = "kube-system"

  values = [
    yamlencode({
      autoDiscovery = {
        clusterName = module.eks.cluster_name
      }

      awsRegion = var.aws_region

      rbac = {
        serviceAccount = {
          name = "cluster-autoscaler"
          annotations = {
            "eks.amazonaws.com/role-arn" = module.cluster_autoscaler_irsa.iam_role_arn
          }
        }
      }

      # autoDiscovery.clusterName above already generates
      # --node-group-auto-discovery; do NOT duplicate it here or the CAS
      # discovers each ASG twice and double-scales with balance-similar-node-groups.
      extraArgs = {
        "balance-similar-node-groups"   = "true"
        "skip-nodes-with-system-pods"   = "false"
        "scale-down-delay-after-add"       = var.cas_scale_down_delay_after_add
        "scale-down-unneeded-time"         = var.cas_scale_down_unneeded_time
        "scale-down-utilization-threshold" = var.cas_scale_down_utilization_threshold
      }

      nodeSelector = {
        role = "system"
      }

      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]

      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "300m", memory = "256Mi" }
      }
    })
  ]

  depends_on = [module.eks, helm_release.keda]
}
