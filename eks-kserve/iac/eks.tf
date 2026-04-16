module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  depends_on = [ module.vpc ]

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true # Restrict to your CIDR in production

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

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

  # System node group — runs Knative, Istio, KServe controllers
  # Scaled by AWS Cluster Autoscaler (not Karpenter) for predictable system component placement.
  #
  # Each node group is pinned to a dedicated subnet slice so node IPs are visible
  # at a glance: system=10.0.1x.xx, cpu=10.0.2x.xx, gpu=10.0.3x.xx. The slice
  # indices here must match the ordering in vpc.tf's private_subnets list.
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

    # CPU inference node pool — autoscaled by CAS in response to Pending pods from KPA
    cpu_inference = {
      name           = "cpu-inference"
      instance_types = [var.cpu_node_instance_type]
      min_size       = var.cpu_node_min
      max_size       = var.cpu_node_max
      desired_size   = var.cpu_node_desired
      subnet_ids     = slice(module.vpc.private_subnets, 3, 6) # 10.0.2x.xx

      labels = {
        role               = "inference"
        "inference/type"   = "cpu"
      }

      autoscaling_group_tags = {
        "k8s.io/cluster-autoscaler/enabled"                              = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"                  = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/role"             = "inference"
        "k8s.io/cluster-autoscaler/node-template/label/inference/type"   = "cpu"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 200
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }
    }

    # GPU inference node pool — autoscaled by CAS in response to Pending pods from KPA
    gpu_inference = {
      name           = "gpu-inference"
      instance_types = [var.gpu_node_instance_type]
      min_size       = var.gpu_node_min
      max_size       = var.gpu_node_max
      desired_size   = var.gpu_node_desired
      # GPU subnets are indices 6-8 (10.0.3x.xx), one per AZ. Not every AZ
      # offers every GPU instance type (e.g. g5 is absent from ap-southeast-2b),
      # so filter to only AZs where the instance type is actually available.
      # Without this the ASG tries the unsupported AZ, fails, and enters backoff
      # which blocks scale-up entirely.
      subnet_ids = [
        for i, sid in slice(module.vpc.private_subnets, 6, 9) : sid
        if contains(
          data.aws_ec2_instance_type_offerings.gpu.locations,
          data.aws_availability_zones.available.names[i % length(data.aws_availability_zones.available.names)]
        )
      ]

      ami_type = "AL2023_x86_64_NVIDIA" # Amazon Linux 2023 with NVIDIA drivers pre-installed

      labels = {
        role                          = "inference"
        "inference/type"              = "gpu"
        "nvidia.com/gpu.present"      = "true"
      }

      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]

      autoscaling_group_tags = {
        "k8s.io/cluster-autoscaler/enabled"                                    = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"                        = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/role"                   = "inference"
        "k8s.io/cluster-autoscaler/node-template/label/inference/type"         = "gpu"
        "k8s.io/cluster-autoscaler/node-template/label/nvidia.com/gpu.present" = "true"
        "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"         = "true:NoSchedule"
        "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"     = "1"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 500 # Large disk for model weight caching
            volume_type           = "gp3"
            iops                  = 6000
            throughput            = 500
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
