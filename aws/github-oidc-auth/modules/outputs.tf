# outputs.tf - Output values for GitHub OIDC Auth module

output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions IAM role"
  value       = aws_iam_role.github_actions_role.arn
}

output "github_actions_role_name" {
  description = "Name of the GitHub Actions IAM role"
  value       = aws_iam_role.github_actions_role.name
}

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

output "allowed_branches" {
  description = "List of GitHub branches that can assume the role"
  value       = var.github_branches
}

output "allowed_environments" {
  description = "List of GitHub environments that can assume the role"
  value       = var.github_environments
}
