resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "57.0.1"
  namespace        = "monitoring"
  create_namespace = true

  values = [
    yamlencode({
      grafana = {
        adminPassword = "changeme-in-production" # Use AWS Secrets Manager in prod
        nodeSelector  = { role = "system" }
        tolerations = [{
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
        # Service stays ClusterIP — Grafana is reached via the Istio NLB on
        # grafana.${local.public_domain}. No sub-path needed now that it has its
        # own hostname.
        persistence = {
          enabled = true
          size    = "10Gi"
        }
        # Pre-load KServe dashboard
        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [{
              name            = "default"
              orgId           = 1
              folder          = ""
              type            = "file"
              disableDeletion = false
              options         = { path = "/var/lib/grafana/dashboards/default" }
            }]
          }
        }
      }

      prometheus = {
        prometheusSpec = {
          nodeSelector = { role = "system" }
          tolerations = [{
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
          retention    = "30d"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources   = { requests = { storage = "50Gi" } }
              }
            }
          }
          # Scrape KServe model server metrics.
          # IMPORTANT: the `keep` on container name `kserve-container` is required.
          # Without it, Prometheus scrapes every declared port on the pod, including
          # queue-proxy:8012 (user-traffic port). Hits on :8012 count as real requests
          # in Knative's concurrency metric and prevent scale-to-zero, pinning GPU nodes
          # up indefinitely. The metrics path comes from the KServe-set annotation.
          additionalScrapeConfigs = [
            {
              job_name        = "kserve-model-servers"
              honor_labels    = true
              kubernetes_sd_configs = [{ role = "pod" }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_label_serving_kserve_io_inferenceservice"]
                  action        = "keep"
                  regex         = ".+"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_container_name"]
                  action        = "keep"
                  regex         = "kserve-container"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_annotation_prometheus_kserve_io_path"]
                  action        = "replace"
                  regex         = "(.+)"
                  target_label  = "__metrics_path__"
                },
                {
                  source_labels = ["__meta_kubernetes_namespace"]
                  target_label  = "namespace"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_label_serving_kserve_io_inferenceservice"]
                  target_label  = "model"
                }
              ]
            },
            # Knative activator metrics — shows request buffering during
            # scale-from-zero (activator_request_concurrency, _count, _latencies).
            # Safe to scrape: runs in knative-serving, not in model pods.
            {
              job_name        = "knative-activator"
              scrape_interval = "5s"
              kubernetes_sd_configs = [{
                role = "pod"
                namespaces = { names = ["knative-serving"] }
              }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_label_app"]
                  action        = "keep"
                  regex         = "activator"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_container_port_number"]
                  action        = "keep"
                  regex         = "9090"
                }
              ]
            },
            # Knative autoscaler metrics — shows scaling decisions
            # (autoscaler_desired_pods, _actual_pods, _not_ready_pods,
            # _panic_request_concurrency, _stable_request_concurrency).
            {
              job_name        = "knative-autoscaler"
              scrape_interval = "5s"
              kubernetes_sd_configs = [{
                role = "pod"
                namespaces = { names = ["knative-serving"] }
              }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_label_app"]
                  action        = "keep"
                  regex         = "autoscaler"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_container_port_number"]
                  action        = "keep"
                  regex         = "9090"
                }
              ]
            }
          ]
        }
      }

      alertmanager = {
        alertmanagerSpec = {
          nodeSelector = { role = "system" }
          tolerations = [{
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
        }
      }

      # The operator deployment + its admission-webhook patch Job + kube-state-metrics
      # all schedule separately from prometheus/grafana/alertmanager and need their
      # own node pinning, else they stall Pending on a CriticalAddonsOnly-tainted cluster.
      prometheusOperator = {
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
        admissionWebhooks = {
          patch = {
            nodeSelector = { role = "system" }
            tolerations = [{
              key      = "CriticalAddonsOnly"
              operator = "Equal"
              value    = "true"
              effect   = "NoSchedule"
            }]
          }
        }
      }

      "kube-state-metrics" = {
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }
    })
  ]

  depends_on = [module.eks]
}

# Expose Grafana through the existing Istio NLB at path /grafana.
# Reuses the same `istio=ingress` pods that the Knative ingress and KServe
# inference services already share, so no extra LoadBalancer/NLB is provisioned.
#
# Path-based routing instead of host-based avoids needing DNS — works directly
# against the raw ELB hostname. If you wire Route 53 in later you can swap to
# host-based by changing `hosts` and dropping the URI rewrite.
resource "kubectl_manifest" "grafana_gateway" {
  yaml_body = <<-YAML
    apiVersion: networking.istio.io/v1beta1
    kind: Gateway
    metadata:
      name: grafana-gateway
      namespace: monitoring
    spec:
      selector:
        istio: ingress
      servers:
        - hosts:
            - "*"
          port:
            name: http
            number: 8080
            protocol: HTTP
  YAML

  server_side_apply = true
  force_conflicts   = true

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubectl_manifest" "grafana_virtualservice" {
  yaml_body = <<-YAML
    apiVersion: networking.istio.io/v1beta1
    kind: VirtualService
    metadata:
      name: grafana
      namespace: monitoring
    spec:
      hosts:
        - "grafana.${local.public_domain}"
      gateways:
        - grafana-gateway
      http:
        - route:
            - destination:
                host: kube-prometheus-stack-grafana.monitoring.svc.cluster.local
                port:
                  number: 80
  YAML

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.grafana_gateway]
}
