# Dedicated namespace for RayService / RayCluster workloads so cluster-wide
# quotas and network policies can target Ray pods specifically without
# affecting kube-system, monitoring, or the KubeRay operator itself.
resource "kubernetes_namespace" "ray_serve" {
  metadata {
    name = "ray-serve"

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "ray.io/workload"              = "serve"
    }
  }

  depends_on = [module.eks]
}

# Service account the Ray head/worker pods should run as. Annotated for IRSA
# so S3 downloads use the scoped ray_serving role instead of the node IAM.
resource "kubernetes_service_account" "ray_serving" {
  metadata {
    name      = "ray-serving"
    namespace = kubernetes_namespace.ray_serve.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = module.ray_serving_irsa.iam_role_arn
    }
  }
}

resource "kubernetes_resource_quota" "ray_serve" {
  metadata {
    name      = "ray-serve-quota"
    namespace = kubernetes_namespace.ray_serve.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"            = "64"
      "requests.memory"         = "256Gi"
      "limits.cpu"              = "128"
      "limits.memory"           = "512Gi"
      "requests.nvidia.com/gpu" = tostring(var.gpu_node_max)
      "limits.nvidia.com/gpu"   = tostring(var.gpu_node_max)
      "count/rayservices.ray.io" = "10"
      "count/rayclusters.ray.io" = "10"
    }
  }

  depends_on = [kubernetes_namespace.ray_serve]
}

resource "kubernetes_limit_range" "ray_serve" {
  metadata {
    name      = "ray-serve-limits"
    namespace = kubernetes_namespace.ray_serve.metadata[0].name
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

  depends_on = [kubernetes_namespace.ray_serve]
}
