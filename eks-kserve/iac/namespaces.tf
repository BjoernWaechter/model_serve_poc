# =============================================================================
# Per-team namespaces + K8s guardrails
# =============================================================================
# Driven by var.teams — the single source of truth for team scaffolding (see
# variables.tf). argocd_projects.tf reads the same variable to create one
# AppProject per team (when source_repos is set).

resource "kubernetes_namespace" "team" {
  for_each = var.teams

  metadata {
    name = each.key

    labels = merge(
      {
        "istio-injection"                    = "enabled"
        "serving.kserve.io/inferenceservice" = "enabled"
        "app.kubernetes.io/managed-by"       = "terraform"
        "team"                               = each.key
      },
      each.value.namespace_labels,
    )
  }

  depends_on = [module.eks]
}

resource "kubernetes_resource_quota" "team" {
  for_each = var.teams

  metadata {
    name      = "team-quota"
    namespace = each.key
  }

  spec {
    hard = {
      "requests.cpu"                              = each.value.resource_quota.requests_cpu
      "requests.memory"                           = each.value.resource_quota.requests_memory
      "limits.cpu"                                = each.value.resource_quota.limits_cpu
      "limits.memory"                             = each.value.resource_quota.limits_memory
      "requests.nvidia.com/gpu"                   = each.value.resource_quota.requests_gpu
      "limits.nvidia.com/gpu"                     = each.value.resource_quota.limits_gpu
      "count/inferenceservices.serving.kserve.io" = each.value.resource_quota.inference_services
    }
  }

  depends_on = [kubernetes_namespace.team]
}

resource "kubernetes_limit_range" "team" {
  for_each = var.teams

  metadata {
    name      = "team-limits"
    namespace = each.key
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = each.value.limit_range.default_cpu
        memory = each.value.limit_range.default_memory
      }
      default_request = {
        cpu    = each.value.limit_range.default_request_cpu
        memory = each.value.limit_range.default_request_memory
      }
    }
  }

  depends_on = [kubernetes_namespace.team]
}

# Network policy — deny all cross-namespace traffic
resource "kubernetes_network_policy" "team_isolation" {
  for_each = var.teams

  metadata {
    name      = "deny-cross-namespace"
    namespace = each.key
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    # Allow ingress from Istio ingress gateway only
    ingress {
      from {
        namespace_selector {
          match_labels = { name = "istio-system" }
        }
      }
    }

    # Allow egress to kube-dns and within namespace
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
    }

    egress {
      to {
        pod_selector {}
      }
    }

    # Allow egress to S3 (model artifact downloads)
    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
          ]
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace.team]
}
