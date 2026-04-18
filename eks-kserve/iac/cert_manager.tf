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


  depends_on = [module.eks]
}
