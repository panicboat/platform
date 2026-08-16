# outputs.tf - Outputs for the eks-holmesgpt module.

output "pod_identity_role_name" {
  description = "IAM role name bound to holmesgpt:holmesgpt SA via Pod Identity Association. Used for verification."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_role_arn" {
  description = "IAM role ARN for holmesgpt:holmesgpt SA Pod Identity binding."
  value       = aws_iam_role.pod_identity.arn
}

output "pod_identity_association_id" {
  description = "Pod Identity Association ID. Used for verification (aws eks describe-pod-identity-association)."
  value       = aws_eks_pod_identity_association.this.association_id
}

output "pod_identity_association_arn" {
  description = "Pod Identity Association ARN."
  value       = aws_eks_pod_identity_association.this.association_arn
}
