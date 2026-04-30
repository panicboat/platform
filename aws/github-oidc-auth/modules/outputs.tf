# outputs.tf - Output values for GitHub OIDC Auth module

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider"
  value       = local.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the GitHub OIDC provider"
  value       = "https://token.actions.githubusercontent.com"
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group for GitHub Actions"
  value       = aws_cloudwatch_log_group.github_actions_logs.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group for GitHub Actions"
  value       = aws_cloudwatch_log_group.github_actions_logs.arn
}

output "github_org" {
  description = "GitHub organization name"
  value       = var.github_org
}

output "github_repos" {
  description = "GitHub repository names"
  value       = var.github_repos
}

output "allowed_environments" {
  description = "List of GitHub environments that can assume the role"
  value       = var.github_environments
}

output "plan_role_arn" {
  description = "ARN of the plan-only GitHub Actions IAM role"
  value       = aws_iam_role.plan.arn
}

output "plan_role_name" {
  description = "Name of the plan-only GitHub Actions IAM role"
  value       = aws_iam_role.plan.name
}

output "apply_role_arn" {
  description = "ARN of the apply GitHub Actions IAM role"
  value       = aws_iam_role.apply.arn
}

output "apply_role_name" {
  description = "Name of the apply GitHub Actions IAM role"
  value       = aws_iam_role.apply.name
}
