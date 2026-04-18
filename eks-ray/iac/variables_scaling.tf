# =============================================================================
# Scaling & autoscaling variables
# =============================================================================

# -----------------------------------------------------------------------------
# Managed node group sizing (system + cpu). GPU nodes come from Karpenter and
# are bounded by gpu_node_max (total nvidia.com/gpu limit on the NodePool).
# -----------------------------------------------------------------------------

variable "system_node_min" {
  description = "Minimum number of system nodes (runs KubeRay operator, Karpenter, CAS, monitoring)"
  type        = number
  default     = 2
}

variable "system_node_max" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 6
}

variable "system_node_desired" {
  description = "Initial desired number of system nodes"
  type        = number
  default     = 2
}

variable "cpu_node_min" {
  description = "Minimum number of CPU nodes (hosts Ray head + CPU workers)"
  type        = number
  default     = 1
}

variable "cpu_node_max" {
  description = "Maximum number of CPU nodes"
  type        = number
  default     = 5
}

variable "cpu_node_desired" {
  description = "Initial desired number of CPU nodes"
  type        = number
  default     = 1
}

variable "gpu_node_max" {
  description = "Maximum number of GPUs across all Karpenter-provisioned GPU nodes (NodePool nvidia.com/gpu limit)"
  type        = number
  default     = 4
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler (CAS) behaviour — manages system + cpu node groups only
# -----------------------------------------------------------------------------

variable "cas_scale_down_delay_after_add" {
  description = "How long CAS waits after a scale-up before considering scale-down (e.g. \"5m\")"
  type        = string
  default     = "2m"
}

variable "cas_scale_down_unneeded_time" {
  description = "How long a node must be unneeded before CAS removes it (e.g. \"5m\")"
  type        = string
  default     = "2m"
}

variable "cas_scale_down_utilization_threshold" {
  description = "CPU/memory utilization below which a node is considered for scale-down (0.0–1.0)"
  type        = string
  default     = "0.5"
}

# -----------------------------------------------------------------------------
# ALB tuning — long idle_timeout to absorb GPU cold starts (5–10 min) and
# long-running batch inference. Equivalent to the Istio NLB tcpKeepalive in
# the kserve cluster.
# -----------------------------------------------------------------------------

variable "alb_idle_timeout_seconds" {
  description = "ALB idle_timeout.timeout_seconds — raises the default 60s to cover GPU cold starts and long inference calls"
  type        = number
  default     = 1200
}
