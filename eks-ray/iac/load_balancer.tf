# AWS Load Balancer Controller — provisions ALBs for the Ray dashboard,
# Ray Serve, MLflow, and Grafana ingresses. Supports the keep-alive /
# idle-timeout annotations that the in-tree provider lacks.
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

  depends_on = [module.eks, time_sleep.wait_k8s_ready]
}
