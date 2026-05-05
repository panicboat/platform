# outputs.tf - Outputs for the eks-traces module.

output "bucket_name" {
  description = "S3 bucket name for Tempo trace data. Referenced by Sub-project 4 helmfile values (tempo chart storage.trace.s3)."
  value       = module.s3.s3_bucket_id
}

output "bucket_path_prefix" {
  description = "Bucket path prefix for env isolation (e.g., 'production'). Used as Tempo object storage prefix."
  value       = var.environment
}

output "pod_identity_role_name" {
  description = "IAM role name bound to monitoring:tempo SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for monitoring:tempo SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}
