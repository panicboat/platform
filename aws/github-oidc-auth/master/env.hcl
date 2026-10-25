locals {
  environment = "master"
  aws_region  = "ap-northeast-1"

  github_org   = "panicboat"
  github_repos = ["monorepo", "platform"]

  github_environments = [
    "master"
  ]

  additional_iam_policies = []

  # Manages account-level OIDC provider singleton for the management account.
  create_oidc_provider = true
  oidc_provider_arn    = ""

  max_session_duration = 14400

  additional_tags = {
    Component = "github-oidc-auth"
    Owner     = "panicboat"
  }
}
