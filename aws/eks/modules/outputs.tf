# outputs.tf - Outputs for the EKS cluster module.

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "EKS cluster Kubernetes version"
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Cluster security group created by EKS"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Node security group"
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN (for Karpenter / external addons)"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "IRSA OIDC provider URL"
  value       = module.eks.oidc_provider
}

output "cluster_iam_role_arn" {
  description = "Cluster IAM role ARN"
  value       = module.eks.cluster_iam_role_arn
}

output "admin_role_arn" {
  description = "ARN of the IAM role for human kubectl admin access"
  value       = aws_iam_role.eks_admin.arn
}

output "admin_role_name" {
  description = "Name of the IAM role for human kubectl admin access"
  value       = aws_iam_role.eks_admin.name
}
