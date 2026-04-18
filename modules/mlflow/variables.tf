variable "namespace" {
  description = "Kubernetes namespace the MLflow release lives in"
  type        = string
  default     = "mlflow"
}

variable "chart_version" {
  description = "Bitnami MLflow chart version"
  type        = string
  default     = "5.1.17"
}

variable "aws_account_id" {
  description = "AWS account ID whose ECR pull-through cache hosts the Bitnami images"
  type        = string
}

variable "region" {
  description = "AWS region — used for the ECR pull-through cache and the S3 artifact endpoint"
  type        = string
}

variable "artifact_bucket" {
  description = "S3 bucket for MLflow model artifacts. Must be writable by the IAM role in service_account_role_arn."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes ServiceAccount name for the tracking pod. Set to a stable value so IRSA annotations map deterministically."
  type        = string
  default     = "mlflow"
}

variable "service_account_role_arn" {
  description = "IAM role ARN to annotate on the tracking ServiceAccount for IRSA. Leave null to skip IRSA wiring (e.g. for MinIO-backed installs)."
  type        = string
  default     = null
}

variable "host" {
  description = "Public hostname the ALB Ingress routes (e.g. mlflow.example.com)"
  type        = string
}

variable "alb_scheme" {
  description = "ALB scheme: internet-facing or internal"
  type        = string
  default     = "internet-facing"
}

variable "alb_idle_timeout_seconds" {
  description = "ALB idle timeout — must exceed slowest expected MLflow request"
  type        = number
  default     = 60
}
