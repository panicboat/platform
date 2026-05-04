# outputs.tf - Outputs for the karpenter module.

output "node_role_name" {
  description = "Node IAM role name for EC2 instances launched by Karpenter (referenced by EC2NodeClass.spec.role)"
  value       = module.karpenter.node_iam_role_name
}

output "interruption_queue_name" {
  description = "SQS queue name for EC2 interruption events (referenced by Helm chart values.settings.interruptionQueue)"
  value       = module.karpenter.queue_name
}
