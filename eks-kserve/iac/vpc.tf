module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Private subnets are carved per node-group so each group's node IPs are
  # easy to spot at a glance:
  #   system nodes → 10.0.1x.xx   (indices 0-2)
  #   cpu nodes    → 10.0.2x.xx   (indices 3-5)
  #   gpu nodes    → 10.0.3x.xx   (indices 6-8)
  # The VPC module spreads subnets across the AZ list by index-mod-AZ-count,
  # so slot 0/3/6 → AZ-a, 1/4/7 → AZ-b, 2/5/8 → AZ-c. Keep the ordering stable
  # — eks.tf slices this list into per-node-group subnet_ids by index.
  private_subnets = [
    "10.0.10.0/24", # system   AZ-a
    "10.0.11.0/24", # system   AZ-b
    "10.0.12.0/24", # system   AZ-c
    "10.0.20.0/24", # cpu      AZ-a
    "10.0.21.0/24", # cpu      AZ-b
    "10.0.22.0/24", # cpu      AZ-c
    "10.0.30.0/24", # gpu      AZ-a  (eks.tf filters to AZs where GPU type is offered)
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
  one_nat_gateway_per_az = true # 3 NATs (1 per AZ) regardless of subnet count — set single_nat_gateway=true in non-prod to cut to 1
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # Required tags for EKS to discover subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
