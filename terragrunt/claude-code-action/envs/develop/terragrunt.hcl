# terragrunt.hcl - Terragrunt configuration for monorepo environment

# Include root configuration
include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Include environment-specific configuration
include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules
terraform {
  source = "../../modules"
}

# Input variables for the module
inputs = {
  # Project configuration
  project_name = "claude-code-action"
  environment  = include.env.locals.environment

  # GitHub configuration
  github_org   = "panicboat"  # Update this with your GitHub organization
  github_repos = include.env.locals.github_repos

  # AWS configuration
  aws_region           = include.env.locals.aws_region
  claude_model_region  = include.env.locals.claude_model_region

  # OIDC configuration
  oidc_provider_arn = include.env.locals.oidc_provider_arn

  # IAM configuration
  max_session_duration    = include.env.locals.max_session_duration
  additional_iam_policies = include.env.locals.additional_iam_policies

  # Bedrock configuration
  bedrock_models = include.env.locals.bedrock_models

  # Tags
  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project     = "claude-code-action"
      ManagedBy   = "terragrunt"
      Repository  = "panicboat/monorepo"
    }
  )
}
