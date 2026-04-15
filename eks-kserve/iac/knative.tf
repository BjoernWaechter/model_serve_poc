locals {
  knative_version = "v1.13.1"
}

# Create the knative-serving namespace explicitly so that all namespaced
# resources in the serving-core manifest can depend on it.  The manifest
# itself also contains the namespace object; server_side_apply + force_conflicts
# ensures the two don't clash.
resource "kubectl_manifest" "knative_serving_ns" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: knative-serving
      labels:
        app.kubernetes.io/managed-by: terraform
  YAML

  server_side_apply = true
  force_conflicts   = true

  depends_on = [module.eks]
}

data "http" "knative_crds" {
  url = "https://github.com/knative/serving/releases/download/knative-${local.knative_version}/serving-crds.yaml"
}

data "kubectl_file_documents" "knative_crds" {
  content = data.http.knative_crds.response_body
}

resource "kubectl_manifest" "knative_crds" {
  for_each          = data.kubectl_file_documents.knative_crds.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [module.eks]
}

data "http" "knative_core" {
  url = "https://github.com/knative/serving/releases/download/knative-${local.knative_version}/serving-core.yaml"
}

data "kubectl_file_documents" "knative_core" {
  content = data.http.knative_core.response_body
}

resource "kubectl_manifest" "knative_core" {
  for_each          = data.kubectl_file_documents.knative_core.manifests
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.knative_crds,
    kubectl_manifest.knative_serving_ns,
  ]
}

data "http" "knative_istio" {
  url = "https://github.com/knative/net-istio/releases/download/knative-${local.knative_version}/net-istio.yaml"
}

data "kubectl_file_documents" "knative_istio" {
  content = data.http.knative_istio.response_body
}

locals {
  # Resources we manage separately because they need selector overrides
  knative_istio_excluded = [
    "knative-local-gateway",
    "knative-ingress-gateway",
  ]

  knative_istio_filtered = {
    for k, v in data.kubectl_file_documents.knative_istio.manifests : k => v
    if !anytrue([for name in local.knative_istio_excluded : strcontains(v, "name: ${name}")])
  }
}

# Knative Istio integration — excludes Gateway and Service resources that
# need selector overrides (managed separately below).
resource "kubectl_manifest" "knative_istio" {
  for_each          = local.knative_istio_filtered
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    kubectl_manifest.knative_core,
    helm_release.istiod,
  ]
}

# Use the NLB hostname as the Knative domain so services are exposed externally.
# Requests to <service>.<namespace>.<nlb-hostname> are routed by the ingress gateway.
# For production, replace with a real domain and set up DNS / Route 53.
resource "kubectl_manifest" "knative_config_domain" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: config-domain
      namespace: knative-serving
    data:
      "${data.kubernetes_service.istio_ingress.status[0].load_balancer[0].ingress[0].hostname}": ""
  YAML

  depends_on = [
    kubectl_manifest.knative_core,
    helm_release.istio_ingress,
  ]
}

data "kubernetes_service" "istio_ingress" {
  metadata {
    name      = "istio-ingress"
    namespace = "istio-system"
  }

  depends_on = [helm_release.istio_ingress]
}

# Override knative-local-gateway Service and Gateway — net-istio defaults to
# selector istio=ingressgateway, but the Istio gateway Helm chart labels pods
# with istio=ingress (matching the release name).
resource "kubectl_manifest" "knative_local_gateway_svc" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: knative-local-gateway
      namespace: istio-system
      labels:
        networking.knative.dev/ingress-provider: istio
    spec:
      type: ClusterIP
      selector:
        istio: ingress
      ports:
        - name: http2
          port: 80
          targetPort: 8081
          protocol: TCP
  YAML

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.knative_istio]
}

resource "kubectl_manifest" "knative_local_gateway" {
  yaml_body = <<-YAML
    apiVersion: networking.istio.io/v1beta1
    kind: Gateway
    metadata:
      name: knative-local-gateway
      namespace: knative-serving
      labels:
        networking.knative.dev/ingress-provider: istio
    spec:
      selector:
        istio: ingress
      servers:
        - hosts:
            - "*"
          port:
            name: http
            number: 8081
            protocol: HTTP
  YAML

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.knative_istio]
}

resource "kubectl_manifest" "knative_ingress_gateway" {
  yaml_body = <<-YAML
    apiVersion: networking.istio.io/v1beta1
    kind: Gateway
    metadata:
      name: knative-ingress-gateway
      namespace: knative-serving
      labels:
        networking.knative.dev/ingress-provider: istio
    spec:
      selector:
        istio: ingress
      servers:
        - hosts:
            - "*"
          port:
            name: http
            number: 80
            protocol: HTTP
  YAML

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.knative_istio]
}

# Knative autoscaler config — tune scale-to-zero behaviour
resource "kubectl_manifest" "knative_config_autoscaler" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: config-autoscaler
      namespace: knative-serving
    data:
      scale-to-zero-grace-period: "${var.knative_scale_to_zero_grace_period}"
      scale-to-zero-pod-retention-period: "${var.knative_scale_to_zero_pod_retention}"
      stable-window: "${var.knative_stable_window}"
      panic-window-percentage: "${var.knative_panic_window_percentage}"
      panic-threshold-percentage: "${var.knative_panic_threshold_percentage}"
      max-scale-up-rate: "${var.knative_max_scale_up_rate}"
      max-scale-down-rate: "${var.knative_max_scale_down_rate}"
      target-burst-capacity: "${var.knative_target_burst_capacity}"
      requests-per-second-target-default: "${var.knative_rps_target}"
      allow-zero-initial-scale: "${var.knative_allow_zero_initial_scale}"
  YAML

  depends_on = [kubectl_manifest.knative_core]
}

# Allow GPU tolerations and node selectors on Knative pod specs.
# Uses kubernetes_config_map_v1_data to patch only our keys into the existing
# config-features ConfigMap (deployed by knative_core) without overwriting it.
resource "kubernetes_config_map_v1_data" "knative_config_features" {
  metadata {
    name      = "config-features"
    namespace = "knative-serving"
  }

  data = {
    "kubernetes.podspec-tolerations"  = "enabled"
    "kubernetes.podspec-nodeselector" = "enabled"
  }

  force = true

  depends_on = [kubectl_manifest.knative_core]
}
