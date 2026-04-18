variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "rayserve"
}

variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-2"
}

variable "aws_account_id" {
  description = "AWS account ID (used by mlflow.tf to reference the ECR image registry)"
  type        = string
  default     = ""
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# -----------------------------------------------------------------------------
# Public DNS — Route 53 hosted zone the cluster's external services live under.
# All public subdomains (grafana, mlflow, *.ray, …) are created as ALIAS
# records pointing at the corresponding ALB inside this zone. The domain name
# itself is derived from the hosted zone via data.aws_route53_zone.main in
# route53.tf, so only the zone ID needs to be supplied here.
# -----------------------------------------------------------------------------

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for the public domain. Set in terraform.tfvars."
  type        = string
}

# -----------------------------------------------------------------------------
# Instance types
# -----------------------------------------------------------------------------

variable "system_node_instance_type" {
  description = "Instance type for the system node group (KubeRay operator, Karpenter, CAS, monitoring)"
  type        = string
  default     = "m6i.xlarge"
}

variable "cpu_node_instance_type" {
  description = "Instance type for the CPU node group (Ray head + CPU workers)"
  type        = string
  default     = "m6i.2xlarge"
}

variable "gpu_node_instance_type" {
  description = "Instance type for Karpenter-provisioned GPU nodes"
  type        = string
  default     = "g5.2xlarge" # 1x A10G GPU / 24GB VRAM — matches the kserve cluster
}

# -----------------------------------------------------------------------------
# Karpenter
# -----------------------------------------------------------------------------

variable "karpenter_version" {
  description = "Karpenter chart + CRD version"
  type        = string
  default     = "1.6.3"
}

variable "karpenter_enabled" {
  description = "Install Karpenter and the GPU NodePool"
  type        = bool
  default     = true
}

variable "karpenter_cr_enabled" {
  description = "Enable Capacity Reservation feature gate (ODCR / Capacity Blocks for ML)"
  type        = bool
  default     = false
}

variable "karpenter_capacity_type" {
  description = "Karpenter capacity type: 'on-demand' or 'spot'"
  type        = string
  default     = "on-demand"
}

variable "karpenter_consolidate_after" {
  description = "How long a Karpenter node must be empty before consolidation"
  type        = string
  default     = "600s"
}

# -----------------------------------------------------------------------------
# Optional components
# -----------------------------------------------------------------------------

variable "install_mlflow" {
  description = "Install the MLflow tracking server"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "model-serving"
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}
