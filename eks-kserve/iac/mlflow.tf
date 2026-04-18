module "mlflow" {
  count = var.install_mlflow ? 1 : 0

  source = "../../modules/mlflow"

  aws_account_id = var.aws_account_id
  region         = var.aws_region
  host           = "mlflow.${local.public_domain}"

  alb_idle_timeout_seconds = var.alb_idle_timeout_seconds

  # Share the KServe model artifact bucket so registered models live at s3://
  # URIs the InferenceService storage-initializer can pull directly.
  artifact_bucket          = aws_s3_bucket.model_artifacts.id
  service_account_role_arn = module.mlflow_irsa[0].iam_role_arn

  depends_on = [
    kubernetes_storage_class_v1.ebs_gp3, # mlflow PVCs bind against the default SC
    helm_release.aws_lb_controller,      # ALB Ingress needs the controller running
  ]
}
