module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Private subnets are carved per node-group so node IPs are easy to spot at a
  # glance:
  #   system nodes       → 10.0.1x.xx   (indices 0-2)
  #   cpu nodes          → 10.0.2x.xx   (indices 3-5)
  #   gpu (Karpenter)    → 10.0.3x.xx   (indices 6-8) — tagged karpenter.sh/discovery
  # The VPC module spreads subnets across the AZ list by index-mod-AZ-count,
  # so slot 0/3/6 → AZ-a, 1/4/7 → AZ-b, 2/5/8 → AZ-c.
  private_subnets = [
    "10.0.10.0/24", # system   AZ-a
    "10.0.11.0/24", # system   AZ-b
    "10.0.12.0/24", # system   AZ-c
    "10.0.20.0/24", # cpu      AZ-a
    "10.0.21.0/24", # cpu      AZ-b
    "10.0.22.0/24", # cpu      AZ-c
    "10.0.30.0/24", # gpu      AZ-a  (Karpenter selects by AZ + discovery tag)
    "10.0.31.0/24", # gpu      AZ-b
    "10.0.32.0/24", # gpu      AZ-c
  ]
  private_subnet_names = [
    "${var.cluster_name}-system-a",
    "${var.cluster_name}-system-b",
    "${var.cluster_name}-system-c",
    "${var.cluster_name}-cpu-a",
    "${var.cluster_name}-cpu-b",
    "${var.cluster_name}-cpu-c",
    "${var.cluster_name}-gpu-a",
    "${var.cluster_name}-gpu-b",
    "${var.cluster_name}-gpu-c",
  ]
  public_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 48),
    cidrsubnet(var.vpc_cidr, 8, 49),
    cidrsubnet(var.vpc_cidr, 8, 50),
  ]

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
  enable_dns_hostnames   = true
  enable_dns_support     = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Tag only the GPU-designated subnets (indices 6-8, 10.0.3x.xx) with
# karpenter.sh/discovery so Karpenter provisions GPU nodes exclusively into
# that slice. The managed system/cpu node groups pin to their own subnet
# slices via eks.tf, so the tag does not affect them.
resource "aws_ec2_tag" "karpenter_gpu_subnet" {
  for_each = { for i, sid in slice(module.vpc.private_subnets, 6, 9) : i => sid }

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}
