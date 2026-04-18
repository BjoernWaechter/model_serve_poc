module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  depends_on = [ module.vpc ]

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true # Restrict to your CIDR in production

  access_entries = {
    principal = {
      principal_arn = "arn:aws:iam::768871556035:user/temp_admin"
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Karpenter-managed inference nodes join the cluster via the karpenter
  # module's access entry; see karpenter.tf. This tag is how Karpenter
  # discovers the node security group when launching instances.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # EKS Managed Add-ons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
    aws-efs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.efs_csi_irsa.iam_role_arn
    }
  }

  # System node group — runs Knative, Istio, KServe controllers, and Karpenter
  # itself. Scaled by AWS Cluster Autoscaler for predictable system component
  # placement. Pinned to subnets 10.0.1x.xx; the CPU (10.0.2x.xx) and GPU
  # (10.0.3x.xx) subnet slices are now managed by Karpenter NodePools
  # (see karpenter.tf) selected via the karpenter.sh/discovery tags in vpc.tf.
  eks_managed_node_groups = {
    system = {
      name           = "system"
      instance_types = [var.system_node_instance_type]
      min_size       = var.system_node_min
      max_size       = var.system_node_max
      desired_size   = var.system_node_desired
      subnet_ids     = slice(module.vpc.private_subnets, 0, 3) # 10.0.1x.xx

      labels = {
        role = "system"
      }

      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]

      # Required tags for AWS Cluster Autoscaler to discover and manage this node group
      autoscaling_group_tags = {
        "k8s.io/cluster-autoscaler/enabled"                  = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"      = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/role" = "system"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }
    }
  }

  # Grant cluster admin to the Terraform caller
  enable_cluster_creator_admin_permissions = true

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Required for Istio sidecar injection webhook
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to node all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }
}
