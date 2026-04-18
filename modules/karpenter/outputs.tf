output "node_iam_role_name" {
  description = "Name of the IAM role assumed by Karpenter-provisioned nodes (referenced by EC2NodeClass.spec.role)"
  value       = module.karpenter.node_iam_role_name
}

output "node_iam_role_arn" {
  description = "ARN of the Karpenter node IAM role"
  value       = module.karpenter.node_iam_role_arn
}

output "controller_iam_role_arn" {
  description = "ARN of the Karpenter controller IAM role (IRSA)"
  value       = module.karpenter.iam_role_arn
}

output "interruption_queue_name" {
  description = "Name of the SQS queue Karpenter watches for EC2 spot/interruption events"
  value       = module.karpenter.queue_name
}
