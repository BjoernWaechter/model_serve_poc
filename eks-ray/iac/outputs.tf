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
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "model_artifact_bucket" {
  description = "S3 bucket for Ray working_dir and model artifacts"
  value       = aws_s3_bucket.model_artifacts.bucket
}

output "efs_model_cache_id" {
  description = "EFS file system ID for shared model weight cache"
  value       = aws_efs_file_system.model_cache.id
}

output "ray_serving_role_arn" {
  description = "IAM role ARN for Ray pods' S3 access (IRSA)"
  value       = module.ray_serving_irsa.iam_role_arn
}

output "ray_dashboard_url" {
  description = "Public Ray dashboard URL"
  value       = "http://dashboard.ray.${local.public_domain}/"
}

output "ray_serve_url" {
  description = "Public Ray Serve endpoint URL"
  value       = "http://serve.ray.${local.public_domain}/"
}

output "grafana_url" {
  description = "Public Grafana URL (admin / changeme-in-production)"
  value       = "http://grafana.${local.public_domain}/"
}

output "mlflow_url" {
  description = "Public MLflow URL (null when install_mlflow=false)"
  value       = var.install_mlflow ? "http://mlflow.${local.public_domain}/" : null
}

output "mlflow_admin_user" {
  description = "MLflow admin username"
  value       = try(module.mlflow[0].admin_user, "")
}

output "mlflow_admin_password" {
  description = "MLflow admin password"
  value       = try(module.mlflow[0].admin_password, "")
  sensitive   = true
}
