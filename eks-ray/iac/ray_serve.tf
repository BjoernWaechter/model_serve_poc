resource "helm_release" "kuberay-operator" {
  name       = "kuberay-operator"
  repository = "https://ray-project.github.io/kuberay-helm/"
  chart      = "kuberay-operator"
  version    = "1.5.1"

  depends_on = [time_sleep.wait_k8s_ready]

  namespace = "kuberay-system"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "time_sleep" "wait_ray_operator_ready" {
  depends_on = [helm_release.kuberay-operator]

  create_duration  = "30s"
  destroy_duration = "30s"
}


resource "kubernetes_service_v1" "ray_dashboard" {
  metadata {
    name      = "ray-dashboard"
    namespace = "default"
    labels = {
      app = "ray-dashboard"
    }
  }

  spec {
    selector = {
      "ray.io/node-type" = "head"
    }

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
    namespace = "default"
    labels = {
      app = "ray-serve"
    }
  }

  spec {
    selector = {
      "ray.io/node-type" = "head"
    }

    port {
      name        = "serve"
      port        = 8000
      target_port = 8000
    }

    type = "ClusterIP"
  }
  depends_on = [time_sleep.wait_ray_operator_ready]
}


resource "kubernetes_ingress_v1" "ray_dashboard" {
  metadata {
    name      = "ray-dashboard"
    namespace = "default"

    annotations = {
      "kubernetes.io/ingress.class"                  = "alb"
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/listen-ports"       = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path"   = "/"
      "alb.ingress.kubernetes.io/backend-protocol"   = "HTTP"
      "alb.ingress.kubernetes.io/group.name"         = "ray-group"
    }
  }

  spec {
    rule {
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

  depends_on = [kubernetes_service_v1.ray_dashboard]
}

resource "kubernetes_ingress_v1" "ray_serve" {
  metadata {
    name      = "ray-serve"
    namespace = "default"

    annotations = {
      "kubernetes.io/ingress.class"                  = "alb"
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/listen-ports"       = "[{\"HTTP\": 8000}]"
      "alb.ingress.kubernetes.io/healthcheck-path"   = "/"
      "alb.ingress.kubernetes.io/backend-protocol"   = "HTTP"
      "alb.ingress.kubernetes.io/group.name"         = "ray-group"
    }
  }

  spec {
    rule {
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

  depends_on = [kubernetes_service_v1.ray_serve]
}


# data "aws_lb" "selected" {
#   tags = {
#     Environment = "production"
#     Service     = "web"
#   }
# }

# # Output the DNS URL
# output "lb_url" {
#   value = data.aws_lb.selected.dns_name
# }
