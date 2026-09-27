locals {
  environment = "develop"
  aws_region  = "us-east-1"

  github_org  = "panicboat"
  github_repos = ["monorepo","platform"]

  github_environments = [
    "develop"
  ]

  additional_iam_policies = [
  ]

  create_oidc_provider = true
  oidc_provider_arn    = ""

  max_session_duration = 3600

  # Develop-specific resource tags
  additional_tags = {
    Component    = "github-oidc-auth"
    Owner        = "panicboat"
  }
}
