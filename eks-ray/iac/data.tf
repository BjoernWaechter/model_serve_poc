data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

# Discover which AZs actually offer the chosen GPU instance type so Karpenter
# NodePool AZ requirements can be restricted to supported zones only.
# e.g. g5 is not offered in ap-southeast-2b, and without this filter Karpenter
# will attempt and fail in that AZ before succeeding elsewhere.
data "aws_ec2_instance_type_offerings" "gpu" {
  filter {
    name   = "instance-type"
    values = [var.gpu_node_instance_type]
  }
  location_type = "availability-zone"
}
