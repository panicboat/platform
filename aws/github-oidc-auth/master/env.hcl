locals {
  environment = "master"
  aws_region  = "ap-northeast-1"

  github_org   = "panicboat"
  github_repos = ["monorepo", "platform"]

  github_environments = [
    "master"
  ]

  additional_iam_policies = []

  claude_code_oidc_subjects = [
    "repo:panicboat/monorepo:environment:claude-code-action",
    "repo:panicboat/platform:environment:claude-code-action",
  ]
  claude_code_bedrock_models = [
    "anthropic.claude-haiku-4-5-20251001-v1:0",
    "anthropic.claude-sonnet-4-6",
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
