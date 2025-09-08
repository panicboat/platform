# outputs.tf - Output values for GitHub Repository Management module

output "repository_id" {
  description = "GitHub repository ID"
  value       = github_repository.repository.repo_id
}

output "repository_node_id" {
  description = "GitHub repository node ID"
  value       = github_repository.repository.node_id
}

output "repository_full_name" {
  description = "Full name of the repository (org/repo)"
  value       = github_repository.repository.full_name
}

output "repository_html_url" {
  description = "URL to the repository on GitHub"
  value       = github_repository.repository.html_url
}

output "repository_http_clone_url" {
  description = "URL that can be provided to git clone to clone the repository"
  value       = github_repository.repository.http_clone_url
}

output "repository_ssh_clone_url" {
  description = "URL that can be provided to git clone to clone the repository via SSH"
  value       = github_repository.repository.ssh_clone_url
}

output "branch_protection_rules" {
  description = "Information about created branch protection rules"
  value = {
    for key, rule in github_branch_protection.branches : key => {
      id      = rule.id
      pattern = rule.pattern
    }
  }
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group"
  value       = aws_cloudwatch_log_group.github_repository_logs.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group"
  value       = aws_cloudwatch_log_group.github_repository_logs.arn
}
