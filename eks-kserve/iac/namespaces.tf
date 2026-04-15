locals {
  teams = ["team-a", "team-b", "team-platform"]
}

resource "kubernetes_namespace" "team" {
  for_each = toset(local.teams)

  metadata {
    name = each.value

    labels = {
      "istio-injection"                         = "enabled"
      "serving.kserve.io/inferenceservice"      = "enabled"
      "app.kubernetes.io/managed-by"            = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_resource_quota" "team" {
  for_each = toset(local.teams)

  metadata {
    name      = "team-quota"
    namespace = each.value
  }

  spec {
    hard = {
      "requests.cpu"            = "32"
      "requests.memory"         = "128Gi"
      "limits.cpu"              = "64"
      "limits.memory"           = "256Gi"
      "requests.nvidia.com/gpu" = "4"
      "limits.nvidia.com/gpu"   = "4"
      "count/inferenceservices.serving.kserve.io" = "20"
    }
  }

  depends_on = [kubernetes_namespace.team]
}

resource "kubernetes_limit_range" "team" {
  for_each = toset(local.teams)

  metadata {
    name      = "team-limits"
    namespace = each.value
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "1Gi"
      }
      default_request = {
        cpu    = "100m"
        memory = "256Mi"
      }
    }
  }

  depends_on = [kubernetes_namespace.team]
}

# Network policy — deny all cross-namespace traffic
resource "kubernetes_network_policy" "team_isolation" {
  for_each = toset(local.teams)

  metadata {
    name      = "deny-cross-namespace"
    namespace = each.value
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
