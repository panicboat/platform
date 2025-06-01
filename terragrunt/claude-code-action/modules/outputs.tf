# outputs.tf - Outputs for Claude Code Action module

output "iam_role_arn" {
  description = "ARN of the IAM role for Claude Code Action"
  value       = aws_iam_role.claude_code_action_role.arn
}

output "iam_role_name" {
  description = "Name of the IAM role for Claude Code Action"
  value       = aws_iam_role.claude_code_action_role.name
}

output "bedrock_policy_arn" {
  description = "ARN of the Bedrock policy"
  value       = aws_iam_policy.bedrock_claude_policy.arn
}


output "bedrock_models" {
  description = "List of allowed Bedrock Claude models"
  value       = var.bedrock_models
}

output "claude_model_region" {
  description = "AWS region where Claude models are available"
  value       = var.claude_model_region
}

output "github_actions_configuration" {
  description = "Configuration object for GitHub Actions"
  value = {
    role_arn            = aws_iam_role.claude_code_action_role.arn
    aws_region          = var.aws_region
    claude_model_region = var.claude_model_region
    bedrock_models      = var.bedrock_models
  }
}
