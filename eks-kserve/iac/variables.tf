variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "kserve-cluster"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-2" # Sydney — closest to NZ
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35" # Latest available on EKS as of April 2026 (1.35 does not exist yet)
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# -----------------------------------------------------------------------------
# Public DNS — Route 53 hosted zone the cluster's external services live under.
# All public subdomains (grafana, llm1, iris, …) are created as ALIAS records
# pointing at the Istio NLB inside this zone. The domain name itself is
# derived from the hosted zone via data.aws_route53_zone.main in route53.tf,
# so only the zone ID needs to be supplied here.
# -----------------------------------------------------------------------------
variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for the public domain. Set in terraform.tfvars."
  type        = string
}

variable "cpu_node_instance_type" {
  description = "Instance type for CPU inference node pool"
  type        = string
  default     = "m6i.2xlarge" # 8 vCPU / 32GB — good for small CPU models
}

variable "gpu_node_instance_type" {
  description = "Instance type for GPU inference node pool"
  type        = string
  default     = "g5.2xlarge" # 1x A10G GPU / 24GB VRAM — cost-effective for inference
}

variable "system_node_instance_type" {
  description = "Instance type for system/control-plane components"
  type        = string
  default     = "m6i.xlarge"
}

# Node pool min/max and scaling variables are in variables_scaling.tf

variable "deploy_test" {
  description = "Deploy a test InferenceService (sklearn-iris) for validation"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# MLflow
# -----------------------------------------------------------------------------

variable "install_mlflow" {
  description = "Install MLflow (Bitnami chart) fronted by its own ALB Ingress"
  type        = bool
  default     = true
}

variable "aws_account_id" {
  description = "AWS account ID whose ECR pull-through cache hosts the Bitnami chart images (required when install_mlflow=true)"
  type        = string
  default     = ""
}

variable "alb_idle_timeout_seconds" {
  description = "ALB idle timeout for the MLflow Ingress"
  type        = number
  default     = 60
}

# -----------------------------------------------------------------------------
# Argo CD
# -----------------------------------------------------------------------------

variable "install_argocd" {
  description = "Install Argo CD (argo-helm chart) fronted by its own ALB Ingress at argocd.<public_domain>"
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (https://artifacthub.io/packages/helm/argo/argo-cd)"
  type        = string
  default     = "9.5.2"
}

# GitHub repo credentials for Argo CD. Optional — leave empty for public-repo,
# unauthenticated access. Setting these avoids GitHub's stricter unauthenticated
# rate limits (and is required for private repos). The PAT only needs `repo:read`
# (or `public_repo` for public-only). Stored as a labeled k8s Secret that Argo CD
# picks up declaratively, so the PAT does not end up in the Helm release object.
variable "argocd_github_url_prefix" {
  description = "URL prefix the github-creds apply to (e.g. https://github.com/your-org). Any Application repoURL under this prefix uses the credential."
  type        = string
  default     = ""
}

variable "argocd_github_pat" {
  description = "GitHub Personal Access Token used by Argo CD to authenticate git fetches. Leave empty to skip creating the credential."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "model-serving"
    ManagedBy   = "terraform"
    Environment = "production"
  }
}
