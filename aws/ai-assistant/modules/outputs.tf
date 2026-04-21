# outputs.tf

output "cli_role_arn" {
  description = "ARN of the CLI IAM role"
  value       = aws_iam_role.cli_role.arn
}

output "cli_role_name" {
  description = "Name of the CLI IAM role"
  value       = aws_iam_role.cli_role.name
}

output "actions_role_arn" {
  description = "ARN of the GitHub Actions IAM role"
  value       = aws_iam_role.actions_role.arn
}

output "actions_role_name" {
  description = "Name of the GitHub Actions IAM role"
  value       = aws_iam_role.actions_role.name
}

output "bedrock_policy_arn" {
  description = "ARN of the shared Bedrock policy"
  value       = aws_iam_policy.bedrock_claude_policy.arn
}

output "bedrock_inference_profiles" {
  description = "List of allowed Bedrock cross-region inference profiles"
  value       = var.bedrock_inference_profiles
}

output "claude_model_region" {
  description = "AWS region where Claude models are available"
  value       = var.claude_model_region
}

