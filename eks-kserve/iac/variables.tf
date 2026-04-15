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

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "model-serving"
    ManagedBy   = "terraform"
    Environment = "production"
  }
}
