# =============================================================================
# EKS Cluster with KServe — Model Serving Platform
# =============================================================================
# Prerequisites:
#   - AWS CLI configured with sufficient IAM permissions
#   - terraform >= 1.5.0
#   - kubectl, helm installed locally
#
# Usage:
#   terraform init
#   terraform plan -var="cluster_name=test-cluster"
#   terraform apply
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket = "terraform-state-768871556035"
    key    = "eks-kserve-cluster"
    region = "ap-southeast-2"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
