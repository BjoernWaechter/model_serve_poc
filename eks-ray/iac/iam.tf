# =============================================================================
# IRSA (IAM Roles for Service Accounts)
# =============================================================================

# EBS CSI Driver
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# EFS CSI Driver (for model weight caching shared across GPU nodes)
module "efs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-efs-csi"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
}

# AWS Load Balancer Controller
module "aws_lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-aws-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# S3 access for Ray working_dir / model artifact downloads. Scoped to the
# cluster's artifact bucket and the public Ray example bucket that the
# text-summarizer RayService references.
resource "aws_iam_policy" "ray_s3_access" {
  name        = "${var.cluster_name}-ray-s3-access"
  description = "S3 access for Ray working_dir and model artifact downloads"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.model_artifacts.arn,
          "${aws_s3_bucket.model_artifacts.arn}/*",
          "arn:aws:s3:::ray-${var.region}",
          "arn:aws:s3:::ray-${var.region}/*",
        ]
      }
    ]
  })
}

# Bind to the Ray pod service account (default "default" SA in the
# ray-serve namespace; update namespace_service_accounts if you use a
# dedicated SA). Replaces the node-IAM-role fallback that the existing
# Bottlerocket + httpPutResponseHopLimit=2 hack relies on.
module "ray_serving_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-ray-serving"

  role_policy_arns = {
    s3 = aws_iam_policy.ray_s3_access.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "ray-serve:default",
        "ray-serve:ray-serving",
      ]
    }
  }
}

# Cluster Autoscaler (manages the system + cpu managed node groups only;
# Karpenter handles the GPU pool and is not ASG-based, so CAS ignores it).
module "cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                        = "${var.cluster_name}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}
