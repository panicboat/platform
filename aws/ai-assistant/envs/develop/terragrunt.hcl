# terragrunt.hcl - develop environment

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

include "cli" {
  path   = "cli.hcl"
  expose = true
}

include "actions" {
  path   = "actions.hcl"
  expose = true
}

terraform {
  source = "../../modules"
}

inputs = {
  project_name = "ai-assistant"
  environment  = include.env.locals.environment

  # AWS configuration
  aws_region          = include.env.locals.aws_region
  claude_model_region = include.env.locals.claude_model_region

  # IAM configuration
  max_session_duration    = include.env.locals.max_session_duration
  additional_iam_policies = include.env.locals.additional_iam_policies

  # CLI role
  trusted_principal_arns = include.cli.locals.trusted_principal_arns

  # Actions role
  github_org        = "panicboat"
  github_repos      = include.actions.locals.github_repos
  oidc_provider_arn = include.actions.locals.oidc_provider_arn

  # Tags
  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "ai-assistant"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
