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
          # Scrape KServe model server metrics
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
