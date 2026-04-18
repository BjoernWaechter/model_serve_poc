# Cluster Autoscaler — manages the system + cpu managed node groups.
# Karpenter nodes are standalone EC2 instances (no ASG), so CAS auto-discovery
# via `k8s.io/cluster-autoscaler/enabled` ASG tags ignores them. The two
# autoscalers therefore coexist without fighting over the same nodes.
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

      awsRegion = var.region

      rbac = {
        serviceAccount = {
          name = "cluster-autoscaler"
          annotations = {
            "eks.amazonaws.com/role-arn" = module.cluster_autoscaler_irsa.iam_role_arn
          }
        }
      }

      extraArgs = {
        "balance-similar-node-groups"      = "true"
        "skip-nodes-with-system-pods"      = "false"
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

  depends_on = [module.eks, time_sleep.wait_k8s_ready]
}
