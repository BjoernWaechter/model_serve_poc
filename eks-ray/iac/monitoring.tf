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
          retention = "30d"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources   = { requests = { storage = "50Gi" } }
              }
            }
          }
          # Ray-specific scrape configs. The KubeRay operator labels head
          # and worker pods with ray.io/node-type and exposes Ray metrics
          # on port 8080 (Prometheus endpoint enabled by default in Ray
          # 2.x). The dashboard (:8265) is scraped as a liveness check.
          additionalScrapeConfigs = [
            {
              job_name        = "ray-pods"
              honor_labels    = true
              scrape_interval = "15s"
              kubernetes_sd_configs = [{ role = "pod" }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_label_ray_io_node_type"]
                  action        = "keep"
                  regex         = "head|worker"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_container_port_number"]
                  action        = "keep"
                  regex         = "8080"
                },
                {
                  source_labels = ["__meta_kubernetes_namespace"]
                  target_label  = "namespace"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_label_ray_io_cluster"]
                  target_label  = "ray_cluster"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_label_ray_io_node_type"]
                  target_label  = "ray_node_type"
                }
              ]
            },
            # KubeRay operator metrics — reconcile loop, RayService/RayCluster
            # status, queue depths.
            {
              job_name        = "kuberay-operator"
              scrape_interval = "15s"
              kubernetes_sd_configs = [{
                role       = "pod"
                namespaces = { names = ["kuberay-system"] }
              }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
                  action        = "keep"
                  regex         = "kuberay-operator"
                }
              ]
            },
            # NVIDIA DCGM exporter — per-GPU utilisation, memory, temperature.
            # Deployed by the GPU Operator as a DaemonSet on GPU nodes.
            {
              job_name        = "nvidia-dcgm"
              scrape_interval = "15s"
              kubernetes_sd_configs = [{
                role       = "pod"
                namespaces = { names = ["gpu-operator"] }
              }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_label_app"]
                  action        = "keep"
                  regex         = "nvidia-dcgm-exporter"
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

  depends_on = [module.eks, time_sleep.wait_k8s_ready]
}

# Expose Grafana through an ALB on grafana.<domain>. Unlike the kserve setup
# there is no Istio mesh here — the ingress goes directly to the ALB and
# the AWS Load Balancer Controller targets the Grafana ClusterIP service.
resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = "monitoring"

    annotations = {
      "kubernetes.io/ingress.class"                     = "alb"
      "alb.ingress.kubernetes.io/scheme"                = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"           = "ip"
      "alb.ingress.kubernetes.io/listen-ports"          = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path"      = "/api/health"
      "alb.ingress.kubernetes.io/backend-protocol"      = "HTTP"
      "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=${var.alb_idle_timeout_seconds}"
      "external-dns.alpha.kubernetes.io/hostname"       = "grafana.${local.public_domain}"
    }
  }

  spec {
    rule {
      host = "grafana.${local.public_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "kube-prometheus-stack-grafana"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.kube_prometheus_stack, helm_release.aws_lb_controller]
}
