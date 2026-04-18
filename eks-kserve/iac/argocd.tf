# =============================================================================
# Argo CD — GitOps controller, UI fronted by its own ALB Ingress.
# =============================================================================
# Installed as an available cluster tool (not currently wired to self-manage
# any Terraform-owned addon). UI is reachable at http://argocd.<public_domain>.
#
# All Argo CD components run on the system MNG (role=system + CriticalAddonsOnly
# toleration) to match the other control-plane addons — inference nodes stay
# reserved for user workloads.
#
# --insecure on the argocd-server lets the ALB talk plain HTTP to the pod.
# We mirror mlflow's HTTP-only ALB pattern here; promote to HTTPS by adding
# an ACM cert annotation to the Ingress when the public domain gets a cert.

resource "kubernetes_namespace" "argocd" {
  count = var.install_argocd ? 1 : 0

  metadata {
    name = "argocd"

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  count = var.install_argocd ? 1 : 0

  name       = "argocd"
  namespace  = kubernetes_namespace.argocd[0].metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [
    yamlencode({
      global = {
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }

      # Let the ALB terminate — server serves plain HTTP so the ALB's HTTP
      # target doesn't hit a self-signed TLS endpoint on the pod.
      configs = {
        params = {
          "server.insecure" = true
        }
      }

      server = {
        service = {
          type = "ClusterIP"
        }
      }

      # Dex is the SSO sidecar — not needed for local admin auth.
      dex = {
        enabled = false
      }

      # ApplicationSet and Notifications controllers aren't used yet; keep them
      # off to trim the footprint. Flip to true when we start using them.
      applicationSet = {
        enabled = false
      }
      notifications = {
        enabled = false
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.argocd,
    helm_release.aws_lb_controller,
  ]
}

resource "kubernetes_ingress_v1" "argocd" {
  count = var.install_argocd ? 1 : 0

  # Block until the LBC populates status.loadBalancer so the Route 53 alias
  # has a real ALB DNS name on first apply.
  wait_for_load_balancer = true

  metadata {
    name      = "argocd"
    namespace = kubernetes_namespace.argocd[0].metadata[0].name

    annotations = {
      "kubernetes.io/ingress.class"                        = "alb"
      "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/listen-ports"             = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path"         = "/healthz"
      "alb.ingress.kubernetes.io/backend-protocol"         = "HTTP"
      "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=${var.alb_idle_timeout_seconds}"
    }
  }

  spec {
    rule {
      host = "argocd.${local.public_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "argocd-server"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.argocd]
}

# Bootstrap admin password — the chart creates this secret on first install.
# Surfaced as an output so the user can log in immediately; rotate it in the
# UI afterwards (Argo CD supports changing it without touching this secret).
data "kubernetes_secret" "argocd_admin" {
  count = var.install_argocd ? 1 : 0

  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = kubernetes_namespace.argocd[0].metadata[0].name
  }

  depends_on = [helm_release.argocd]
}
