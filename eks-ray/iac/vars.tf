variable "cluster_name" {
  type    = string
  default = "rayserve"
}

variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "aws_account_id" {
  type    = string
  default = "768871556035"
}

variable "install_mlflow" {
  type    = bool
  default = false
}

variable "karpenter_version" {
  description = "Karpenter version"
  type = string
  default = "1.6.3"
}

variable "karpenter_enabled" {
  type    = bool
  default = true
}

variable "karpenter_cr_enabled" {
  type    = bool
  default = false
}

variable "karpenter_capacity_type" {
  description = "Karpenter capacity type: 'on-demand' or 'spot'"
  type = string
  default = "on-demand"
}

variable "karpenter_consolidate_after" {
  description = "Karpenter consolidate-after delay"
  type = string
  default = "600s"
}

variable "karpenter_max_pods" {
  description = "Karpenter kubelet maxPods"
  type = number
  default = 20
}

variable "karpenter_cr_cudaefa_ids" {
  description = "List of capacity reservation IDs for CUDA EFA instances (ODCR or Capacity Blocks, e.g., ['cr-xxx', 'cr-yyy'])"
  type        = list(string)
  default     = []
}

variable "karpenter_cr_cudaefa_tags" {
  description = "Tags to select capacity reservations for CUDA EFA instances (e.g., {purpose = 'distributed-training'})"
  type        = map(string)
  default     = {}
}

variable "karpenter_cr_capacity_types" {
  description = "Karpenter capacity types for capacity reservations: 'on-demand', 'spot', 'reserved'"
  type        = list(string)
  default     = ["on-demand"]
}