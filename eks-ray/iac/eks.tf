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
      tags = {
        "k8s.io/cluster-autoscaler/enabled" = "true"
        "k8s.io/cluster-autoscaler/${module.eks.cluster_name}" = "owned"
      }
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
            encrypted   = true
            delete_on_termination = true
          }
        }
      }
      metadata_options = {
        http_endpoint               = "enabled"
        http_put_response_hop_limit = 2
        http_tokens                 = "required"
      }
      
   }
   rayserve-gpu = {
      partition = "aws"
      instance_types = ["g4dn.xlarge"]
      ami_type       = "AL2023_x86_64_NVIDIA"
      min_size       = 0
      max_size       = 5
      desired_size   = 0
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }
      tags = {
        "k8s.io/cluster-autoscaler/enabled" = "true"
        "k8s.io/cluster-autoscaler/${module.eks.cluster_name}" = "owned"
      }
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
            encrypted   = true
            delete_on_termination = true
          }
        }
      }
      metadata_options = {
        http_endpoint               = "enabled"
        http_put_response_hop_limit = 2
        http_tokens                 = "required"
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

module "cluster_autoscaler" {
  source  = "lablabs/eks-cluster-autoscaler/aws"
  version = "4.0.0"

  cluster_name                     = module.eks.cluster_name
  cluster_identity_oidc_issuer     = module.eks.cluster_oidc_issuer_url
  cluster_identity_oidc_issuer_arn = module.eks.oidc_provider_arn
  irsa_role_name_prefix            = "rayserver-irsa"

  depends_on = [
    module.eks
  ]
}

resource "time_sleep" "wait_k8s_ready" {
  depends_on = [module.eks_blueprints_addons]

  create_duration  = "30s"
  destroy_duration = "30s"
}


resource "helm_release" "nvidia_device_plugin" {
  name = "nvidia-device-plugin"

  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = "kube-addons"
  create_namespace = "true"

  depends_on = [
    module.eks.eks_managed_node_groups  # or your node group resource
  ]

  set {
    name = "version"
    value = "0.19.0"
  }
  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}



resource "aws_iam_policy" "s3_ray_artifact_bucket" {
  name        = "s3-ray-artifact-bucket"
  description = "Allow read-only access to a specific S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::ray-ap-southeast-2",
          "arn:aws:s3:::ray-ap-southeast-2/*"
        ]
      }
    ]
  })
}


resource "aws_iam_role_policy_attachment" "cpu_nodes_s3_read" {
  role       = module.eks.eks_managed_node_groups["rayserve-cpu"].iam_role_name
  policy_arn = aws_iam_policy.s3_ray_artifact_bucket.arn
}

resource "aws_iam_role_policy_attachment" "gpu_nodes_s3_read" {
  role       = module.eks.eks_managed_node_groups["rayserve-gpu"].iam_role_name
  policy_arn = aws_iam_policy.s3_ray_artifact_bucket.arn
}