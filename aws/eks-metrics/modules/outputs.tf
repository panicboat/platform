# outputs.tf - Outputs for the eks-metrics module.

output "bucket_name" {
  description = "S3 bucket name for Thanos long-term metrics storage. Referenced by Sub-project 2 helmfile values (kube-prometheus-stack thanos.objstoreConfig)."
  value       = module.s3.s3_bucket_id
}

output "bucket_path_prefix" {
  description = "Bucket path prefix for env isolation (e.g., 'production'). Used as Thanos object storage prefix."
  value       = var.environment
}

output "pod_identity_role_name" {
  description = "IAM role name bound to monitoring:prometheus SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for monitoring:prometheus SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}
