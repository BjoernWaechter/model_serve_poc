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

# EFS CSI Driver (for GPU model weight caching across nodes)
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

# S3 access for KServe to pull model artifacts
resource "aws_iam_policy" "model_s3_access" {
  name        = "${var.cluster_name}-model-s3-access"
  description = "Allows KServe to pull model artifacts from S3"

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
        ]
      }
    ]
  })
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

# KServe model serving role
# Trusted by the KServe controller and by a `kserve-sa` service account in each
# team namespace — the storage-initializer sidecar runs under the predictor
# pod's SA, so team SAs need S3 read on the model bucket.
module "model_serving_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-model-serving"

  role_policy_arns = {
    s3 = aws_iam_policy.model_s3_access.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = concat(
        ["kserve:kserve-controller-manager"],
        [for team in keys(var.teams) : "${team}:kserve-sa"],
      )
    }
  }
}

# MLflow tracking server: needs S3 read+write on the shared artifact bucket so
# clients can log models through the server (serveArtifacts path) and so future
# operations (signed URL generation, artifact deletion) keep working. KServe's
# own IRSA role is read-only — by design — so we don't reuse it here.
resource "aws_iam_policy" "mlflow_s3_access" {
  count = var.install_mlflow ? 1 : 0

  name        = "${var.cluster_name}-mlflow-s3-access"
  description = "S3 read/write/list for the MLflow tracking server on the model artifact bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.model_artifacts.arn,
          "${aws_s3_bucket.model_artifacts.arn}/*",
        ]
      }
    ]
  })
}

module "mlflow_irsa" {
  count = var.install_mlflow ? 1 : 0

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-mlflow"

  role_policy_arns = {
    s3 = aws_iam_policy.mlflow_s3_access[0].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["mlflow:mlflow"]
    }
  }
}
