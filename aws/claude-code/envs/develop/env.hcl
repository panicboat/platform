# env.hcl - Environment-specific configuration for develop

locals {
  # Environment-specific settings
  environment = "develop"

  # AWS configuration
  aws_region          = "ap-northeast-1"
  claude_model_region = "us-west-2" # Claude models are available in us-west-2

  # Principals allowed to assume the Claude Code role
  trusted_principal_arns = [
    "arn:aws:iam::559744160976:user/panicboat",
  ]

  # IAM configuration
  max_session_duration = 7200 # 2 hours for development work

  # Additional IAM policies (if needed)
  additional_iam_policies = [
    # Add any additional policy ARNs here if needed
  ]

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Purpose     = "claude-code"
    Owner       = "panicboat"
  }
}
