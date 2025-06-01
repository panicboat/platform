# env.hcl - Development environment configuration
locals {
  # Environment metadata
  environment = "develop"
  aws_region  = "ap-northeast-1"

  # GitHub configuration
  github_org  = "panicboat"
  github_repo = "monorepo"

  # GitHub branches that can assume the role in develop
  github_branches = [
    "*"
  ]

  # GitHub environments that can assume the role
  github_environments = [
    "develop"
  ]

  # Additional IAM policies for develop (if needed)
  additional_iam_policies = [
    # Example: Add S3 read-only access for develop
    # "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]

  # OIDC provider settings
  create_oidc_provider = true
  oidc_provider_arn    = ""

  # Session duration (1 hour for develop)
  max_session_duration = 3600

  # Develop-specific resource tags
  additional_tags = {
    CostCenter   = "develop"
    Owner        = "panicboat"
    Purpose      = "github-actions-develop"
    AutoShutdown = "enabled"
  }
}
