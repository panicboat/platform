# env.hcl - Staging environment configuration
locals {
  # Environment metadata
  environment = "staging"
  aws_region  = "ap-northeast-1"

  # GitHub configuration
  github_org  = "panicboat"
  github_repos = ["monorepo","platform"]

  # GitHub branches that can assume the role in staging
  github_branches = [
    "*"
  ]

  # GitHub environments that can assume the role
  github_environments = [
    "staging"
  ]

  # Additional IAM policies for staging (if needed)
  additional_iam_policies = [
    # Example: Add specific policies for staging environment
    # "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]

  # OIDC provider settings (reuse existing provider if created in develop)
  create_oidc_provider = false
  oidc_provider_arn    = "arn:aws:iam::${get_aws_account_id()}:oidc-provider/token.actions.githubusercontent.com"

  # Session duration (2 hours for staging)
  max_session_duration = 7200

  # Staging-specific resource tags
  additional_tags = {
    CostCenter = "staging"
    Owner      = "panicboat"
    Purpose    = "github-actions-staging"
  }
}
