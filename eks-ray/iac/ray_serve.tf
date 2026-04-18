resource "helm_release" "kuberay_operator" {
  name       = "kuberay-operator"
  repository = "https://ray-project.github.io/kuberay-helm/"
  chart      = "kuberay-operator"
  version    = "1.5.1"

  namespace        = "kuberay-system"
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

resource "time_sleep" "wait_ray_operator_ready" {
  depends_on = [helm_release.kuberay_operator]

  create_duration  = "30s"
  destroy_duration = "30s"
}

# ---------------------------------------------------------------------------
# Services — fronted by a shared ALB (alb.ingress.kubernetes.io/group.name
# = ray-group) so both the dashboard and Serve endpoint land on the same
# hostname and Route 53 wildcard aliases resolve correctly.
# ---------------------------------------------------------------------------

resource "kubernetes_service_v1" "ray_dashboard" {
  metadata {
    name      = "ray-dashboard"
    namespace = kubernetes_namespace.ray_serve.metadata[0].name
    labels    = { app = "ray-dashboard" }
  }

  spec {
    selector = { "ray.io/node-type" = "head" }

    port {
      name        = "dashboard"
      port        = 8265
      target_port = 8265
    }

    type = "ClusterIP"
  }
  depends_on = [time_sleep.wait_ray_operator_ready]
}

resource "kubernetes_service_v1" "ray_serve" {
  metadata {
    name      = "ray-serve"
    namespace = kubernetes_namespace.ray_serve.metadata[0].name
    labels    = { app = "ray-serve" }
  }

  spec {
    selector = { "ray.io/node-type" = "head" }

    port {
      name        = "serve"
      port        = 8000
      target_port = 8000
    }

    type = "ClusterIP"
  }
  depends_on = [time_sleep.wait_ray_operator_ready]
}

# ---------------------------------------------------------------------------
# Ingresses — ALB with keep-alive + long idle timeout so long-running Ray
# inference requests (GPU cold start = 5–10 min, large batch prediction)
# don't hit the default ALB 60s idle timeout. Matches the kserve NLB's
# tcpKeepalive behaviour in spirit.
# ---------------------------------------------------------------------------

locals {
  ray_alb_annotations = {
    "kubernetes.io/ingress.class"                        = "alb"
    "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"              = "ip"
    "alb.ingress.kubernetes.io/backend-protocol"         = "HTTP"
    "alb.ingress.kubernetes.io/group.name"               = "ray-group"
    "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=${var.alb_idle_timeout_seconds}"
    "alb.ingress.kubernetes.io/target-group-attributes"  = "deregistration_delay.timeout_seconds=30"
  }
}

resource "kubernetes_ingress_v1" "ray_dashboard" {
  metadata {
    name      = "ray-dashboard"
    namespace = kubernetes_namespace.ray_serve.metadata[0].name

    annotations = merge(local.ray_alb_annotations, {
      "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/"
    })
  }

  spec {
    rule {
      host = "dashboard.ray.${local.public_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.ray_dashboard.metadata[0].name
              port {
                number = 8265
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.ray_dashboard, helm_release.aws_lb_controller]
}

resource "kubernetes_ingress_v1" "ray_serve" {
  metadata {
    name      = "ray-serve"
    namespace = kubernetes_namespace.ray_serve.metadata[0].name

    annotations = merge(local.ray_alb_annotations, {
      # A single ALB listener per group; both ingresses must declare the
      # same listener set, so listen-ports match ray-dashboard above.
      "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/-/routes"
    })
  }

  spec {
    rule {
      host = "serve.ray.${local.public_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.ray_serve.metadata[0].name
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.ray_serve, helm_release.aws_lb_controller]
}
