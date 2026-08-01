# outputs.tf - Outputs for the eks-cost module.

output "pod_identity_role_name" {
  description = "IAM role name bound to monitoring:opencost SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for monitoring:opencost SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}
