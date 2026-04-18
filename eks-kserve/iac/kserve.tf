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

locals {
  # Resources we manage separately so we don't fight kubectl_manifest's
  # force_conflicts = true on every apply. The inferenceservice-config
  # ConfigMap gets a tailored `ingress` block below (domain, domainTemplate).
  kserve_excluded = ["inferenceservice-config"]

  kserve_filtered = {
    for k, v in data.kubectl_file_documents.kserve.manifests : k => v
    if !anytrue([for name in local.kserve_excluded : strcontains(v, "name: ${name}")])
  }

  # Pin the KServe controller deployment to the system MNG. Upstream kserve.yaml
  # ships without a CriticalAddonsOnly toleration, so on a cluster whose only
  # non-inference nodes carry that taint the controller is unschedulable.
  kserve_manifests = {
    for k, v in local.kserve_filtered : k => (
      try(yamldecode(v).kind, "") == "Deployment"
        ? yamlencode(merge(
            yamldecode(v),
            {
              spec = merge(
                yamldecode(v).spec,
                {
                  template = merge(
                    yamldecode(v).spec.template,
                    {
                      spec = merge(
                        yamldecode(v).spec.template.spec,
                        {
                          nodeSelector = merge(
                            try(yamldecode(v).spec.template.spec.nodeSelector, {}),
                            { role = "system" }
                          )
                          tolerations = concat(
                            try(yamldecode(v).spec.template.spec.tolerations, []),
                            [{
                              key      = "CriticalAddonsOnly"
                              operator = "Equal"
                              value    = "true"
                              effect   = "NoSchedule"
                            }]
                          )
                        }
                      )
                    }
                  )
                }
              )
            }
          ))
        : v
    )
  }
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
  for_each          = local.kserve_manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.kserve_crds,
    kubectl_manifest.kserve_ns,
    kubectl_manifest.kserve_inferenceservice_config,
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

locals {
  # Pull the upstream inferenceservice-config CM out of the parsed kserve.yaml
  # so we keep every default data key (storageInitializer, autoscaler, agent,
  # explainers, …) that KServe ships with. We only need to override `ingress`.
  # This stays correct across KServe version bumps: new keys come along for free.
  kserve_isvc_upstream_cm = one([
    for doc in data.kubectl_file_documents.kserve.manifests :
    yamldecode(doc)
    if try(yamldecode(doc).kind, "") == "ConfigMap" &&
       try(yamldecode(doc).metadata.name, "") == "inferenceservice-config"
  ])

  kserve_isvc_ingress_config = jsonencode({
    kserveIngressGateway       = "kserve/kserve-ingress-gateway"
    ingressGateway             = "knative-serving/knative-ingress-gateway"
    knativeLocalGatewayService = "knative-local-gateway.istio-system.svc.cluster.local"
    localGateway               = "knative-serving/knative-local-gateway"
    localGatewayService        = "knative-local-gateway.istio-system.svc.cluster.local"
    ingressClassName           = "istio"
    # All InferenceServices live under the kserve.* subdomain so the root
    # domain stays clean and we can point a single wildcard DNS record and
    # wildcard TLS cert at them. We put "kserve." inside the domain rather
    # than the template — the domainTemplate only accepts simple patterns,
    # embedding a literal middle label like "{{ .Name }}.kserve.{{ .IngressDomain }}"
    # produces surprising output.
    ingressDomain              = "kserve.${local.public_domain}"
    domainTemplate             = "{{ .Name }}.{{ .IngressDomain }}"
    urlScheme                  = "http"
    disableIstioVirtualHost    = false
    disableIngressCreation     = false
    # Leave pathTemplate empty — we're doing domain-based routing. If set, KServe
    # additionally tries to build a path URL and fails with "invalid URI" when
    # the template lacks a leading slash (which the upstream default does).
    pathTemplate               = ""
  })
}

# KServe's inferenceservice-config ConfigMap. Built by merging our custom
# `ingress` block onto the upstream defaults — so every other config key
# (storageInitializer, autoscaler, …) keeps its default. The upstream copy
# is filtered out via local.kserve_excluded above so this doesn't fight it.
resource "kubectl_manifest" "kserve_inferenceservice_config" {
  yaml_body = yamlencode(merge(
    local.kserve_isvc_upstream_cm,
    {
      data = merge(
        local.kserve_isvc_upstream_cm.data,
        { ingress = local.kserve_isvc_ingress_config }
      )
    }
  ))

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.kserve_ns]
}

# KServe caches inferenceservice-config at controller startup and does not
# hot-reload. Trigger a rollout restart whenever the CM contents change so the
# new ingressDomain/domainTemplate values actually take effect.
resource "null_resource" "kserve_controller_restart" {
  triggers = {
    config_hash = sha256(kubectl_manifest.kserve_inferenceservice_config.yaml_body)
  }

  provisioner "local-exec" {
    command = <<-EOT
      CA_FILE=$(mktemp)
      echo "$CA_DATA" | base64 -d > "$CA_FILE"
      trap "rm -f $CA_FILE" EXIT

      TOKEN=$(aws eks get-token --cluster-name "$CLUSTER_NAME" --region "$REGION" --output json | jq -r '.status.token')
      K="kubectl --server=$ENDPOINT --certificate-authority=$CA_FILE --token=$TOKEN"

      $K rollout restart deployment/kserve-controller-manager -n kserve
      $K rollout status  deployment/kserve-controller-manager -n kserve --timeout=120s
    EOT

    environment = {
      CLUSTER_NAME = module.eks.cluster_name
      REGION       = var.aws_region
      ENDPOINT     = module.eks.cluster_endpoint
      CA_DATA      = module.eks.cluster_certificate_authority_data
    }
  }

  depends_on = [
    kubectl_manifest.kserve_inferenceservice_config,
    kubectl_manifest.kserve, # deployment must exist before we can restart it
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
