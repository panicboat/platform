# env.hcl - Production environment configuration
locals {
  # Environment metadata
  environment = "production"
  aws_region  = "ap-northeast-1"

  # GitHub configuration
  github_org  = "panicboat"
  github_repos = ["monorepo","platform"]

  # GitHub branches that can assume the role in production (service-specific)
  github_branches = [
    "*"
  ]

  # GitHub environments that can assume the role
  github_environments = [
    "production"
  ]

  # Additional IAM policies for production (if needed)
  additional_iam_policies = [
    # Example: Add specific policies for production environment
    # "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]

  # OIDC provider settings (reuse existing provider if created in develop)
  create_oidc_provider = false
  oidc_provider_arn    = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"

  # Session duration (4 hours for production)
  max_session_duration = 14400

  # Production-specific resource tags
  additional_tags = {
    CostCenter = "production"
    Owner      = "panicboat"
    Purpose    = "github-actions-production"
    Critical   = "true"
  }
}
