provider "aws" {
  region = var.aws_region
  default_tags { tags = var.tags }

  # Karpenter's subnet/SG discovery tags are written by aws_ec2_tag resources
  # outside the VPC module's view (see vpc.tf). Without this, the VPC module
  # and aws_ec2_tag oscillate on every plan — the VPC module tries to remove
  # the tag it doesn't know about, cascading through module.eks's data
  # sources and producing spurious replace plans on IAM role attachments,
  # access entries, and KMS policies.
  ignore_tags {
    keys = ["karpenter.sh/discovery"]
  }
}

# ECR Public requires us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}
