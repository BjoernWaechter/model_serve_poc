resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = "1.20.3"
  namespace        = "istio-system"
  create_namespace = true

  depends_on = [module.eks]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.20.3"
  namespace  = "istio-system"

  values = [
    yamlencode({
      meshConfig = {
        # TCP keepalives prevent the NLB's 350s idle timeout from dropping
        # long-lived connections during GPU cold starts (5–10 min).  Envoy
        # sends keepalive probes through the NLB every 60s, resetting the
        # idle timer before it fires.
        tcpKeepalive = {
          time     = 60   # seconds idle before first probe
          interval = 60   # seconds between probes
          probes   = 3    # give up after 3 failed probes
        }
      }
      pilot = {
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }
      global = {
        proxy = {
          resources = {
            requests = { cpu = "50m", memory = "64Mi" }
          }
        }
        tolerations = [
          {
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          },
          {
            key      = "nvidia.com/gpu"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
      }
    })
  ]

  depends_on = [helm_release.istio_base]
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller — manages the Istio NLB and supports
# tcp.idle_timeout.seconds via annotations (the in-tree provider does not).
# ---------------------------------------------------------------------------
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.2"
  namespace  = "kube-system"

  values = [
    yamlencode({
      clusterName = var.cluster_name

      serviceAccount = {
        name = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.aws_lb_controller_irsa.iam_role_arn
        }
      }

      nodeSelector = { role = "system" }

      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
    })
  ]

  depends_on = [module.eks]
}

resource "helm_release" "istio_ingress" {
  name       = "istio-ingress"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = "1.20.3"
  namespace  = "istio-system"
  timeout    = 600 # LBC NLB provisioning can take a few minutes

  values = [
    yamlencode({
      nodeSelector = { role = "system" }
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Equal"
        value    = "true" # must be a string — helm `set` coerces "true" to bool
        effect   = "NoSchedule"
      }]
    })
  ]

  set {
    name  = "service.type"
    value = "LoadBalancer"
  }

  # AWS Load Balancer Controller annotations (replaces in-tree "nlb" type).
  # The LBC supports tcp.idle_timeout.seconds which the in-tree provider does not.
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "external"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
    value = "instance"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  # Cross-zone load balancing — without this, NLB IPs in AZs with no healthy
  # targets return "connection refused".
  # NOTE: tcp.idle_timeout.seconds is not available in all regions (e.g. ap-southeast-2).
  # TCP keepalives on the Istio proxy (configured in istiod values above) prevent
  # the NLB's 350s default idle timeout from dropping long-lived cold-start connections.
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-attributes"
    value = "load_balancing.cross_zone.enabled=true"
  }

  # The gateway pod runs as non-root (uid 1337) and cannot bind to privileged
  # ports.  Remap the Service so external port 80 → container port 8080.
  set {
    name  = "service.ports[0].name"
    value = "status-port"
  }
  set {
    name  = "service.ports[0].port"
    value = "15021"
  }
  set {
    name  = "service.ports[0].targetPort"
    value = "15021"
  }
  set {
    name  = "service.ports[1].name"
    value = "http2"
  }
  set {
    name  = "service.ports[1].port"
    value = "80"
  }
  set {
    name  = "service.ports[1].targetPort"
    value = "8080"
  }
  set {
    name  = "service.ports[2].name"
    value = "https"
  }
  set {
    name  = "service.ports[2].port"
    value = "443"
  }
  set {
    name  = "service.ports[2].targetPort"
    value = "8443"
  }

  depends_on = [helm_release.istiod, helm_release.aws_lb_controller]
}

# TCP keepalive on the gateway listener — prevents the NLB's 350s idle timeout
# from dropping long-lived cold-start connections.  meshConfig.tcpKeepalive only
# applies to outbound/upstream connections; this EnvoyFilter adds SO_KEEPALIVE
# on the inbound listener so the gateway sends keepalive probes to the client
# through the NLB, resetting its idle timer.
resource "kubectl_manifest" "gateway_tcp_keepalive" {
  yaml_body = <<-YAML
    apiVersion: networking.istio.io/v1alpha3
    kind: EnvoyFilter
    metadata:
      name: gateway-tcp-keepalive
      namespace: istio-system
    spec:
      workloadSelector:
        labels:
          istio: ingress
      configPatches:
        - applyTo: LISTENER
          match:
            context: GATEWAY
          patch:
            operation: MERGE
            value:
              socket_options:
                - level: 1       # SOL_SOCKET
                  name: 9        # SO_KEEPALIVE
                  int_value: 1
                  state: STATE_LISTENING
                - level: 6       # IPPROTO_TCP
                  name: 4        # TCP_KEEPIDLE
                  int_value: 60
                  state: STATE_LISTENING
                - level: 6       # IPPROTO_TCP
                  name: 5        # TCP_KEEPINTVL
                  int_value: 60
                  state: STATE_LISTENING
                - level: 6       # IPPROTO_TCP
                  name: 6        # TCP_KEEPCNT
                  int_value: 3
                  state: STATE_LISTENING
  YAML

  depends_on = [helm_release.istiod]
}
