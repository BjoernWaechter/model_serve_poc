module "mlflow" {
  count = var.install_mlflow ? 1 : 0

  source = "../../modules/mlflow"

  aws_account_id = var.aws_account_id
  region         = var.region
  host           = "mlflow.${local.public_domain}"

  alb_idle_timeout_seconds = var.alb_idle_timeout_seconds

  depends_on = [
    kubernetes_storage_class_v1.ebs_gp3, # PVCs need the default SC ready before install
    helm_release.aws_lb_controller,      # ALB Ingress needs the controller running
  ]
}
