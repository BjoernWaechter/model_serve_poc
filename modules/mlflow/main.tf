# Pin Postgres credentials in Terraform state so they are stable across
# helm upgrades. Bitnami's Postgres subchart otherwise re-generates a random
# password on every upgrade, producing "password authentication failed for
# user bn_mlflow" — the Secret updates but the on-disk DB still has the old
# password because Postgres's init only runs on a fresh PVC.
resource "random_password" "db_user" {
  length  = 24
  special = false
}

resource "random_password" "db_superuser" {
  length  = 24
  special = false
}

# Point MLflow at the shared S3 artifact bucket instead of the chart's bundled
# MinIO. With serveArtifacts=false, logged models get registered with raw s3://
# source URIs — which KServe's storage-initializer can pull directly (proxied
# mlflow-artifacts:/ URIs would not work with KServe). Credentials come from
# IRSA via the tracking ServiceAccount annotation; useCredentialsInSecret=false
# keeps the chart from injecting static keys.
#
# All S3/IRSA knobs are passed via `set` blocks rather than `values = [...]`
# because the service_account_role_arn is a cross-module computed value — the
# helm provider has a known bug where computed inputs inside `values` cause
# "metadata: was known, but now unknown" errors on apply.
resource "helm_release" "mlflow" {
  name             = "mlflow"
  namespace        = var.namespace
  repository       = "oci://registry-1.docker.io/bitnamicharts/"
  chart            = "mlflow"
  version          = var.chart_version
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

  # Disable bundled MinIO; use AWS S3 as the artifact store.
  set {
    name  = "minio.enabled"
    value = "false"
  }
  set {
    name  = "externalS3.host"
    value = "s3.${var.region}.amazonaws.com"
  }
  set {
    name  = "externalS3.port"
    value = "443"
  }
  set {
    name  = "externalS3.protocol"
    value = "https"
  }
  set {
    name  = "externalS3.bucket"
    value = var.artifact_bucket
  }
  set {
    name  = "externalS3.useCredentialsInSecret"
    value = "false"
  }
  set {
    name  = "externalS3.serveArtifacts"
    value = "false"
  }

  # Region fallback for boto3 when MLFLOW_S3_ENDPOINT_URL isn't enough.
  set {
    name  = "tracking.extraEnvVars[0].name"
    value = "AWS_DEFAULT_REGION"
  }
  set {
    name  = "tracking.extraEnvVars[0].value"
    value = var.region
  }

  # Stable SA name so IRSA annotations map deterministically.
  set {
    name  = "tracking.serviceAccount.create"
    value = "true"
  }
  set {
    name  = "tracking.serviceAccount.name"
    value = var.service_account_name
  }

  # IRSA role annotation — dots in the annotation key are escaped per the
  # helm provider's set-name syntax. Skipped when no role ARN is supplied
  # (e.g. a MinIO-backed install).
  dynamic "set" {
    for_each = var.service_account_role_arn == null ? [] : [var.service_account_role_arn]
    content {
      name  = "tracking.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = set.value
    }
  }

  set_sensitive {
    name  = "postgresql.auth.password"
    value = random_password.db_user.result
  }

  set_sensitive {
    name  = "postgresql.auth.postgresPassword"
    value = random_password.db_superuser.result
  }
}

resource "kubernetes_ingress_v1" "mlflow" {
  # Block until the AWS LB Controller reconciles the Ingress and the ALB is
  # reachable, so the hostname is populated in status.loadBalancer for the
  # caller's Route 53 alias record. Without this the ALB DNS would be null
  # at plan time and the alias would be unresolvable on first apply.
  wait_for_load_balancer = true

  metadata {
    name      = "mlflow"
    namespace = var.namespace

    annotations = {
      "kubernetes.io/ingress.class"                        = "alb"
      "alb.ingress.kubernetes.io/scheme"                   = var.alb_scheme
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/listen-ports"             = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path"         = "/"
      "alb.ingress.kubernetes.io/backend-protocol"         = "HTTP"
      "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=${var.alb_idle_timeout_seconds}"
    }
  }

  spec {
    rule {
      host = var.host
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

data "kubernetes_secret" "mlflow" {
  metadata {
    name      = "mlflow-tracking"
    namespace = var.namespace
  }
  depends_on = [helm_release.mlflow]
}
