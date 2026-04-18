module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.17.1"

  depends_on = [module.vpc]

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  endpoint_public_access  = true # Restrict to your CIDR in production
  endpoint_private_access = true

  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Karpenter-managed GPU nodes join the cluster via the karpenter module's
  # access entry; see karpenter.tf. This tag is how Karpenter discovers the
  # node security group when launching instances.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  addons = {
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
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
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

  # System node group — runs KubeRay operator, Karpenter, monitoring,
  # cluster-autoscaler, and other cluster-wide controllers.
  # Each group is pinned to a dedicated subnet slice so node IPs are
  # visible at a glance: system=10.0.1x.xx, cpu=10.0.2x.xx. GPU nodes
  # come from Karpenter and land in the 10.0.3x.xx slice.
  eks_managed_node_groups = {
    system = {
      name           = "system"
      instance_types = [var.system_node_instance_type]
      min_size       = var.system_node_min
      max_size       = var.system_node_max
      desired_size   = var.system_node_desired
      subnet_ids     = slice(module.vpc.private_subnets, 0, 3)

      labels = {
        role = "system"
      }

      taints = {
        critical_addons_only = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

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
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }

    # CPU baseline — hosts the Ray head pod and any CPU-only workers.
    # Autoscaled by CAS in response to Pending pods.
    cpu = {
      name           = "cpu"
      instance_types = [var.cpu_node_instance_type]
      min_size       = var.cpu_node_min
      max_size       = var.cpu_node_max
      desired_size   = var.cpu_node_desired
      subnet_ids     = slice(module.vpc.private_subnets, 3, 6)

      labels = {
        role             = "ray"
        "ray.io/purpose" = "cpu"
      }

      autoscaling_group_tags = {
        "k8s.io/cluster-autoscaler/enabled"                              = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"                  = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/role"             = "ray"
        "k8s.io/cluster-autoscaler/node-template/label/ray.io/purpose"   = "cpu"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 200
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to node all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

data "aws_eks_cluster_auth" "eks" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

# Short wait after EKS + addons so the Kubernetes/Helm providers can connect
# reliably. Used by downstream helm_release resources.
resource "time_sleep" "wait_k8s_ready" {
  depends_on = [module.eks]

  create_duration  = "30s"
  destroy_duration = "30s"
}
