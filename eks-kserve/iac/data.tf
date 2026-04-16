data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.us_east_1 # ECR Public is always us-east-1
}

# Discover which AZs actually offer the chosen GPU instance type.
# g5 instances are not available in every AZ (e.g. ap-southeast-2b has none).
# Used in eks.tf to restrict the GPU node group subnets so the ASG never
# attempts to launch in an unsupported AZ and enters backoff.
data "aws_ec2_instance_type_offerings" "gpu" {
  filter {
    name   = "instance-type"
    values = [var.gpu_node_instance_type]
  }
  location_type = "availability-zone"
}
