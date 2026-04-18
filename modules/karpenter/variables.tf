variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster OIDC provider ARN (for IRSA)"
  type        = string
}

variable "region" {
  description = "AWS region (used to scope the capacity-reservation IAM policy)"
  type        = string
}

variable "account_id" {
  description = "AWS account ID (used to scope the capacity-reservation IAM policy)"
  type        = string
}

variable "karpenter_version" {
  description = "Karpenter chart + CRD version"
  type        = string
  default     = "1.6.3"
}

variable "enable_capacity_reservation" {
  description = "Enable Capacity Reservation feature gate (ODCR / Capacity Blocks for ML) and attach the matching IAM policy"
  type        = bool
  default     = false
}

variable "node_iam_role_additional_policies" {
  description = "Extra IAM policies to attach to the Karpenter-managed node role (map of name => policy ARN)"
  type        = map(string)
  default     = {}
}

variable "controller_resources" {
  description = "Resource requests/limits for the Karpenter controller pod"
  type = object({
    limits   = object({ cpu = string, memory = string })
    requests = object({ cpu = string, memory = string })
  })
  default = {
    limits   = { cpu = "1", memory = "2Gi" }
    requests = { cpu = "1", memory = "2Gi" }
  }
}
