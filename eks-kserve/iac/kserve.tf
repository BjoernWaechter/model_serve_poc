data "http" "kserve_crds" {
  url = "https://github.com/kserve/kserve/releases/download/v0.17.0/kserve-crds.yaml"
}

data "kubectl_file_documents" "kserve_crds" {
  content = data.http.kserve_crds.response_body
}

resource "kubectl_manifest" "kserve_crds" {
  for_each          = data.kubectl_file_documents.kserve_crds.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.knative_core,
    helm_release.istiod,
  ]
}

data "http" "kserve" {
  url = "https://github.com/kserve/kserve/releases/download/v0.17.0/kserve.yaml"
}

data "kubectl_file_documents" "kserve" {
  content = data.http.kserve.response_body
}

# Pre-create the kserve namespace so namespaced resources in kserve.yaml
# don't race against the Namespace document during parallel for_each apply.
resource "kubectl_manifest" "kserve_ns" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: kserve
  YAML

  server_side_apply = true
  force_conflicts   = true

  depends_on = [module.eks]
}

resource "kubectl_manifest" "kserve" {
  for_each          = data.kubectl_file_documents.kserve.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.kserve_crds,
    kubectl_manifest.kserve_ns,
  ]
}

# Default ClusterServingRuntimes (sklearn, xgboost, torchserve, triton, etc.)
# Split out of kserve.yaml since v0.13 — must be applied separately.
data "http" "kserve_cluster_resources" {
  url = "https://github.com/kserve/kserve/releases/download/v0.17.0/kserve-cluster-resources.yaml"
}

data "kubectl_file_documents" "kserve_cluster_resources" {
  content = data.http.kserve_cluster_resources.response_body
}

resource "kubectl_manifest" "kserve_cluster_resources" {
  for_each          = data.kubectl_file_documents.kserve_cluster_resources.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.kserve,
  ]
}

# Annotate KServe service account with IRSA role
resource "kubernetes_annotations" "kserve_sa_irsa" {
  api_version = "v1"
  kind        = "ServiceAccount"

  metadata {
    name      = "kserve-controller-manager"
    namespace = "kserve"
  }

  annotations = {
    "eks.amazonaws.com/role-arn" = module.model_serving_irsa.iam_role_arn
  }

  depends_on = [kubectl_manifest.kserve]
}

# resource "helm_release" "kserve" {
#   name             = "kserve"
#   repository       = "https://kserve.github.io/helm-charts"
#   chart            = "kserve"
#   version          = "v0.13.0"
#   namespace        = "kserve"
#   create_namespace = true

#   values = [
#     yamlencode({
#       kserve = {
#         controller = {
#           nodeSelector = { role = "system" }
#           tolerations = [{
#             key      = "CriticalAddonsOnly"
#             operator = "Equal"
#             value    = "true"
#             effect   = "NoSchedule"
#           }]
#           resources = {
#             requests = { cpu = "100m", memory = "256Mi" }
#             limits   = { cpu = "500m", memory = "512Mi" }
#           }
#         }

#         # Use Knative for serverless (scale-to-zero) deployments
#         deploymentMode = "Serverless"

#         # S3 storage initializer — pulls model weights on pod start
#         storageInitializer = {
#           image = "kserve/storage-initializer:v0.13.0"
#           resources = {
#             requests = { cpu = "100m", memory = "256Mi" }
#             limits   = { cpu = "500m", memory = "1Gi" }
#           }
#         }

#         # Service account for S3 access via IRSA
#         serviceAccountName = "kserve-controller-manager"
#       }
#     })
#   ]

#   depends_on = [
#     helm_release.cert_manager,
#     kubectl_manifest.knative_core,
#     helm_release.istiod,
#   ]
# }

# resource "helm_release" "kserve_runtimes" {
#   name       = "kserve-runtimes"
#   repository = "https://kserve.github.io/helm-charts"
#   chart      = "kserve-runtimes"
#   version    = "v0.13.0"
#   namespace  = "kserve"

#   depends_on = [helm_release.kserve]
# }

# =============================================================================
# EXAMPLE InferenceService — PyTorch model (CPU)
# Uncomment to deploy a sample model after applying infrastructure
# =============================================================================

# resource "kubectl_manifest" "example_pytorch_cpu" {
#   yaml_body = <<-YAML
#     apiVersion: serving.kserve.io/v1beta1
#     kind: InferenceService
#     metadata:
#       name: pytorch-example
#       namespace: team-a
#       annotations:
#         autoscaling.knative.dev/target: "10"
#         autoscaling.knative.dev/scale-to-zero-pod-retention-period: "0s"
#     spec:
#       predictor:
#         minReplicas: 0
#         maxReplicas: 5
#         pytorch:
#           storageUri: s3://${aws_s3_bucket.model_artifacts.bucket}/team-a/a-detector/v1
#           resources:
#             requests:
#               cpu: "1"
#               memory: "4Gi"
#             limits:
#               cpu: "2"
#               memory: "8Gi"
#   YAML
#
#   depends_on = [helm_release.kserve]
# }

# resource "kubectl_manifest" "example_pytorch_gpu" {
#   yaml_body = <<-YAML
#     apiVersion: serving.kserve.io/v1beta1
#     kind: InferenceService
#     metadata:
#       name: pytorch-gpu-example
#       namespace: team-a
#       annotations:
#         autoscaling.knative.dev/target: "5"
#     spec:
#       predictor:
#         minReplicas: 0
#         maxReplicas: 2
#         pytorch:
#           storageUri: s3://${aws_s3_bucket.model_artifacts.bucket}/team-a/large-model/v1
#           resources:
#             requests:
#               cpu: "4"
#               memory: "16Gi"
#               nvidia.com/gpu: "1"
#             limits:
#               cpu: "8"
#               memory: "32Gi"
#               nvidia.com/gpu: "1"
#         tolerations:
#           - key: nvidia.com/gpu
#             operator: Exists
#             effect: NoSchedule
#   YAML
#
#   depends_on = [helm_release.kserve]
# }
