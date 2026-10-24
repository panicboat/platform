locals {
  environment = "master"
  aws_region  = "ap-northeast-1"

  github_org   = "panicboat"
  github_repos = ["monorepo", "platform"]

  github_environments = [
    "master"
  ]

  additional_iam_policies = []

  bedrock_models = ["anthropic.claude-sonnet-4-6"]
  bedrock_oidc_subjects = [
    "repo:panicboat/platform:environment:renovate-major-review",
    "repo:panicboat/monorepo:environment:docs-sync-check",
  ]

  # Manages account-level OIDC provider singleton for the management account.
  create_oidc_provider = true
  oidc_provider_arn    = ""

  max_session_duration = 14400

  additional_tags = {
    Component = "github-oidc-auth"
    Owner     = "panicboat"
  }
}
