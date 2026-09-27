locals {
  environment = "production"
  aws_region  = "ap-northeast-1"

  github_org  = "panicboat"
  github_repos = ["monorepo","platform"]

  github_environments = [
    "production"
  ]

  additional_iam_policies = [
  ]

  create_oidc_provider = true
  oidc_provider_arn    = ""

  max_session_duration = 14400

  # Cross-account role required to resolve hosted zones in the management account during plan.
  assume_role_arns = [
    "arn:aws:iam::559744160976:role/route53-zone-access",
  ]

  additional_tags = {
    Component  = "github-oidc-auth"
    Owner      = "panicboat"
  }
}
