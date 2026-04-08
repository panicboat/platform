# outputs.tf - Outputs for Claude Code module

output "iam_role_arn" {
  description = "ARN of the IAM role for Claude Code"
  value       = aws_iam_role.claude_code_role.arn
}

output "iam_role_name" {
  description = "Name of the IAM role for Claude Code"
  value       = aws_iam_role.claude_code_role.name
}

output "bedrock_policy_arn" {
  description = "ARN of the Bedrock policy"
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

output "claude_code_configuration" {
  description = "Configuration object for local Claude Code CLI"
  value = {
    role_arn                   = aws_iam_role.claude_code_role.arn
    aws_region                 = var.aws_region
    claude_model_region        = var.claude_model_region
    bedrock_inference_profiles = var.bedrock_inference_profiles
  }
}
