resource "helm_release" "mlflow" {
  count = var.install_mlflow ? 1 : 0
  name       = "mlflow"
  namespace  = "mlflow"
  repository = "oci://registry-1.docker.io/bitnamicharts/"
  chart      = "mlflow"
  version    = "5.1.17"

  create_namespace = true

  set {
    name  = "global.imageRegistry"
    value = "${var.aws_account_id}.dkr.ecr.${var.region}.amazonaws.com"
  }
  set {
    name  = "global.security.allowInsecureImages"
    value = "true"
  }
  set {
    name  = "tracking.service.type"
    value = "ClusterIP"
  }

  depends_on = [kubernetes_storage_class_v1.ebs_gp3]

}


resource "kubernetes_ingress_v1" "mlflow" {
  count = var.install_mlflow ? 1 : 0
  metadata {
    name      = "mlflow"
    namespace = "mlflow"

    annotations = {
      "kubernetes.io/ingress.class"                = "alb"
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/"
      "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
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
              name = "mlflow-tracking"
              port {
                number = 80
              }
            }
          }
        }

      }
    }
  }

  depends_on = [helm_release.mlflow]
}

data "kubernetes_ingress_v1" "mlflow" {
  count = var.install_mlflow ? 1 : 0
  metadata {
    name      = "mlflow"
    namespace = "mlflow"
  }
  depends_on = [helm_release.mlflow]
}

output "mlflow_url" {
  value = try("http://${data.kubernetes_ingress_v1.mlflow[0].status[0].load_balancer[0].ingress[0].hostname}/","")
}

data "kubernetes_secret" "mlflow_secret" {
  count = var.install_mlflow ? 1 : 0
  metadata {
    name      = "mlflow-tracking"
    namespace = "mlflow"
  }
  depends_on = [helm_release.mlflow]
}

output "mlflw_admin_user" {
  value = try(nonsensitive(data.kubernetes_secret.mlflow_secret[0].data["admin-user"]),"")
  # sensitive = true  
}

output "mlflw_admin_password" {
  value = try(nonsensitive(data.kubernetes_secret.mlflow_secret[0].data["admin-password"]),"")
}
