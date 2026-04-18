resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.4"
  namespace        = "cert-manager"
  create_namespace = true


  values = [
    yamlencode({
      installCRDs = true
      # cert-manager chart has three separate Deployments (controller, webhook,
      # cainjector) plus a startupapicheck Job. The top-level nodeSelector /
      # tolerations only cover the controller; each sub-component needs its own.
      nodeSelector = { role = "system" }
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
      webhook = {
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }
      cainjector = {
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }
      startupapicheck = {
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }
    })
  ]


  # aws_lb_controller installs a cluster-wide mutating webhook on Services.
  # cert-manager creates Services; without this dependency the webhook has no
  # endpoints yet and the API server rejects the create.
  depends_on = [module.eks, helm_release.aws_lb_controller]
}
