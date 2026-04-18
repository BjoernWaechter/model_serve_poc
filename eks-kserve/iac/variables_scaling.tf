# =============================================================================
# Scaling & autoscaling variables
# =============================================================================

# -----------------------------------------------------------------------------
# Node group sizing
# -----------------------------------------------------------------------------

variable "cpu_node_min" {
  description = "Minimum number of CPU inference nodes (0 = scale to zero)"
  type        = number
  default     = 0
}

variable "cpu_node_max" {
  description = "Maximum number of CPU inference nodes"
  type        = number
  default     = 10
}

variable "gpu_node_min" {
  description = "Minimum number of GPU inference nodes (0 = scale to zero)"
  type        = number
  default     = 0
}

variable "gpu_node_max" {
  description = "Maximum number of GPU inference nodes"
  type        = number
  default     = 2
}

variable "system_node_min" {
  description = "Minimum number of system nodes (runs Knative, Istio, KServe controllers)"
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

variable "cpu_node_desired" {
  description = "Initial desired number of CPU inference nodes"
  type        = number
  default     = 1
}

variable "gpu_node_desired" {
  description = "Initial desired number of GPU inference nodes (0 = scale from zero on first request)"
  type        = number
  default     = 0
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler (CAS) behaviour
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
# Knative autoscaler — controls pod-level scale-to-zero and scaling behaviour
# -----------------------------------------------------------------------------

variable "knative_scale_to_zero_grace_period" {
  description = "Grace period before Knative removes the last pod after traffic drops to zero (e.g. \"30s\")"
  type        = string
  default     = "30s"
}

variable "knative_scale_to_zero_pod_retention" {
  description = "How long to keep pods around after last request before scale-to-zero kicks in (e.g. \"0s\")"
  type        = string
  default     = "0s"
}

variable "knative_stable_window" {
  description = "Time window over which metrics are averaged for stable-mode scaling decisions (e.g. \"60s\")"
  type        = string
  default     = "60s"
}

variable "knative_panic_window_percentage" {
  description = "Panic window as a percentage of the stable window — shorter window for burst detection"
  type        = string
  default     = "10.0"
}

variable "knative_panic_threshold_percentage" {
  description = "Traffic percentage above target that triggers panic mode (e.g. \"200.0\" = 2x target)"
  type        = string
  default     = "200.0"
}

variable "knative_max_scale_up_rate" {
  description = "Maximum ratio of desired-to-current pods during scale-up (e.g. \"1000.0\")"
  type        = string
  default     = "1000.0"
}

variable "knative_max_scale_down_rate" {
  description = "Maximum ratio of current-to-desired pods during scale-down (e.g. \"2.0\")"
  type        = string
  default     = "2.0"
}

variable "knative_target_burst_capacity" {
  description = "Extra capacity maintained above target to absorb traffic bursts (\"0\" = none)"
  type        = string
  default     = "0"
}

variable "knative_rps_target" {
  description = "Default requests-per-second target per pod for the Knative Pod Autoscaler"
  type        = string
  default     = "200"
}

variable "knative_allow_zero_initial_scale" {
  description = "Whether new Knative services can start at zero replicas (scale-to-zero from creation)"
  type        = string
  default     = "true"
}

# -----------------------------------------------------------------------------
# Knative revision progress deadline
# -----------------------------------------------------------------------------

variable "knative_progress_deadline" {
  description = "Maximum time (in seconds) for a Knative revision to become ready — must cover node scale-up + image pull + model load"
  type        = number
  default     = 1200
}
