# =============================================================================
# S3 — Model / artifact store for RayService working_dir and model weights
# =============================================================================

resource "aws_s3_bucket" "model_artifacts" {
  bucket = "${var.cluster_name}-model-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "model_artifacts" {
  bucket                  = aws_s3_bucket.model_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# EFS — Shared model / weight cache across GPU nodes
# Survives pod restarts so Ray workers don't re-download the model on every
# cold start.
# =============================================================================

resource "aws_efs_file_system" "model_cache" {
  creation_token   = "${var.cluster_name}-model-cache"
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  encrypted        = true

  tags = { Name = "${var.cluster_name}-model-cache" }
}

resource "aws_security_group" "efs" {
  name                   = "${var.cluster_name}-efs"
  description            = "EFS mount target security group"
  vpc_id                 = module.vpc.vpc_id
  revoke_rules_on_delete = true

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_efs_mount_target" "model_cache" {
  # EFS allows exactly one mount target per AZ. The VPC module distributes
  # private_subnets by index % len(azs), so the first len(azs) entries are
  # guaranteed to be one-per-AZ. Nodes in later subnets (cpu_, gpu_ groups)
  # reach EFS via intra-AZ VPC routing.
  count           = length(module.vpc.azs)
  file_system_id  = aws_efs_file_system.model_cache.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# =============================================================================
# StorageClass — EBS gp3 (default)
# =============================================================================

resource "kubernetes_storage_class_v1" "ebs_gp3" {
  metadata {
    name = "ebs-gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer" # AZ-pins PVCs to where the pod lands
  allow_volume_expansion = true
  reclaim_policy         = "Retain"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks, time_sleep.wait_k8s_ready]
}
