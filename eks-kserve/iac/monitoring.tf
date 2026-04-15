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
    })
  ]

  depends_on = [module.eks]
}
