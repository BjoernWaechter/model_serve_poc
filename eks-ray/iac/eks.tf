module "eks" {
 source  = "terraform-aws-modules/eks/aws"
 version = "21.17.1"


 name    = "rayserve"
 kubernetes_version = "1.35"

 # Optional
 endpoint_public_access = true
 endpoint_private_access = true

 # Optional: Adds the current caller identity as an administrator via cluster access entry
 enable_cluster_creator_admin_permissions = true



 addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true
      # Raise max pods per node (default ~8–11 for t3.small); with prefix delegation, nodes can schedule many more pods and avoid "Too many pods" + EBS AZ affinity issues.
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true # Enables pod-level IAM via Pod Identity
    }
  }

 eks_managed_node_groups = {
   rayserve-cpu = {
     partition = "aws"
     instance_types = ["t3.xlarge"]
     min_size       = 0
     max_size       = 5
     desired_size   = 1
     iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }
   }
   rayserve-gpu = {
     partition = "aws"
     instance_types = ["g4dn.xlarge"]
     min_size       = 0
     max_size       = 5
     desired_size   = 0
     iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }
   }
 }

 vpc_id     = aws_vpc.main.id
 subnet_ids = aws_subnet.public_subnet.*.id

 tags = {
   Environment = "dev"
   Terraform   = "true"
 }
}



data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_name
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = ">= 1.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_aws_load_balancer_controller    = true

  aws_load_balancer_controller = {
    set = [
      {
        name  = "vpcId"
        value = aws_vpc.main.id
      },
    ]
  }

  depends_on = [module.eks, aws_route_table_association.a]

}


resource "time_sleep" "wait_k8s_ready" {
  depends_on = [module.eks_blueprints_addons]

  create_duration  = "30s"
  destroy_duration = "30s"
}