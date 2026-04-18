output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "model_artifact_bucket" {
  description = "S3 bucket for model artifacts"
  value       = aws_s3_bucket.model_artifacts.bucket
}

output "efs_model_cache_id" {
  description = "EFS file system ID for GPU model weight cache"
  value       = aws_efs_file_system.model_cache.id
}

output "model_serving_role_arn" {
  description = "IAM role ARN for KServe S3 access (IRSA)"
  value       = module.model_serving_irsa.iam_role_arn
}

output "ingress_hostname" {
  description = "NLB hostname for the Istio ingress gateway"
  value       = data.kubernetes_service.istio_ingress.status[0].load_balancer[0].ingress[0].hostname
}

output "grafana_url" {
  description = "Public Grafana URL (admin / changeme-in-production)"
  value       = "http://grafana.${local.public_domain}/"
}

output "llm1_url" {
  description = "Public URL for the phi3 GPU inference service (vLLM OpenAI chat completions)"
  value       = "http://llm1.kserve.${local.public_domain}/v1/chat/completions"
}

output "iris_url" {
  description = "Public URL for the sklearn iris inference service"
  value       = "http://iris.kserve.${local.public_domain}/v1/models/iris:predict"
}

output "mlflow_url" {
  description = "Public MLflow URL (null when install_mlflow=false)"
  value       = var.install_mlflow ? "http://mlflow.${local.public_domain}/" : null
}

output "mlflow_admin_user" {
  description = "MLflow admin username"
  value       = try(nonsensitive(module.mlflow[0].admin_user), "")
}

output "mlflow_admin_password" {
  description = "MLflow admin password"
  value       = try(nonsensitive(module.mlflow[0].admin_password), "")
}

output "argocd_url" {
  description = "Public Argo CD URL (null when install_argocd=false)"
  value       = var.install_argocd ? "http://argocd.${local.public_domain}/" : null
}

output "argocd_admin_user" {
  description = "Argo CD admin username"
  value       = var.install_argocd ? "admin" : null
}

output "argocd_admin_password" {
  description = "Argo CD bootstrap admin password (rotate in the UI after first login)"
  value       = try(nonsensitive(data.kubernetes_secret.argocd_admin[0].data["password"]), "")
}
