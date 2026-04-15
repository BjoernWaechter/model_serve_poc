provider "aws" {
  region                 = var.region
  skip_region_validation = true
}

# provider "kubernetes" {
#     host                   = module.eks.cluster_endpoint
#     cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

#     exec {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       command     = "aws"
#       args = [
#         "eks", "get-token",
#         "--cluster-name", module.eks.cluster_name,
#         "--region",       var.region,
#       ]
#     }
# }

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.eks.token
}


provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region",       var.region,
      ]
    }
  }
}


provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.eks.token
  # load_config_file       = false

  # exec {
  #   api_version = "client.authentication.k8s.io/v1alpha1"
  #   command     = "aws-iam-authenticator"
  #   args = [
  #     "token",
  #     "-i",
  #     module.eks.cluster_id,
  #   ]
  # }
}
