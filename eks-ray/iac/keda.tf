# KEDA — event-driven autoscaling. Optional for Ray; available as an
# alternative to Ray Serve's built-in autoscaling_config when scaling on
# external signals (SQS depth, CloudWatch metrics, etc.).
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.13.0"
  namespace        = "keda"
  create_namespace = true

  values = [
    yamlencode({
      nodeSelector = { role = "system" }
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
    })
  ]

  depends_on = [module.eks, time_sleep.wait_k8s_ready]
}
