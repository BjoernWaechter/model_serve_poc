# ECR Public is always served from us-east-1, regardless of the cluster's region.
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.us_east_1
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.37.0"

  cluster_name = var.cluster_name

  irsa_oidc_provider_arn          = var.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  create_iam_role      = true
  create_node_iam_role = true
  enable_irsa          = true
  create_access_entry  = true
  iam_role_name        = "${var.cluster_name}-karpenter-controller"
  node_iam_role_name   = "${var.cluster_name}-karpenter-node"

  node_iam_role_attach_cni_policy   = true
  node_iam_role_additional_policies = var.node_iam_role_additional_policies

  iam_policy_statements = var.enable_capacity_reservation ? [
    {
      sid       = "AllowDescribeCapacityReservations"
      effect    = "Allow"
      actions   = ["ec2:DescribeCapacityReservations"]
      resources = ["*"]
    },
    {
      sid       = "AllowRunInstancesOnCapacityReservation"
      effect    = "Allow"
      actions   = ["ec2:RunInstances", "ec2:CreateFleet"]
      resources = ["arn:aws:ec2:${var.region}:${var.account_id}:capacity-reservation/*"]
    }
  ] : []
}

resource "helm_release" "karpenter_crd" {
  name             = "karpenter-crd"
  chart            = "karpenter-crd"
  repository       = "oci://public.ecr.aws/karpenter/"
  version          = var.karpenter_version
  namespace        = "karpenter"
  create_namespace = true

}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  chart            = "karpenter"
  cleanup_on_fail  = true
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter/"
  version          = var.karpenter_version
  namespace        = "karpenter"
  timeout          = 300
  wait             = true

  values = [
    yamlencode({
      controller = {
        resources = var.controller_resources
      }
      nodeSelector = {
        role = "system"
      }
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
        featureGates = {
          reservedCapacity = var.enable_capacity_reservation
        }
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
        }
      }
      webhook = {
        enabled = false
      }
    })
  ]

  depends_on = [helm_release.karpenter_crd]

  # See note on helm_release.karpenter_crd — ECR Public token rotation would
  # otherwise cause spurious dirty plans every 12 hours.
  lifecycle {
    ignore_changes = [repository_password, repository_username]
  }
}
