# env.hcl - Environment-specific configuration for monorepo

locals {
  # Environment-specific settings
  environment = "develop"

  # GitHub configuration
  github_repos = ["monorepo"]

  # AWS configuration
  aws_region = "ap-northeast-1"
  claude_model_region = "us-west-2"  # Claude models are available in us-west-2

  # IAM configuration
  max_session_duration = 7200  # 2 hours for development work

  # Existing OIDC provider ARN (update this with your actual ARN)
  # You can get this from the github-oidc-auth module output
  oidc_provider_arn = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"

  # Bedrock models to allow access to
  bedrock_models = [
    "anthropic.claude-3-7-sonnet-20250219-v1:0"
  ]

  # Additional IAM policies (if needed)
  additional_iam_policies = [
    # Add any additional policy ARNs here if needed
    # Example: "arn:aws:iam::aws:policy/ReadOnlyAccess"
  ]

  # Environment-specific tags
  environment_tags = {
    Environment = local.environment
    Purpose     = "claude-code-action-monorepo"
    CostCenter  = "engineering"
    Owner       = "panicboat"
  }
}
