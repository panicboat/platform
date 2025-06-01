# terragrunt.hcl - Staging environment Terragrunt configuration

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

# Environment-specific inputs
inputs = {
  # Core configuration from env.hcl
  aws_region               = include.env.locals.aws_region
  github_org               = include.env.locals.github_org
  github_repo              = include.env.locals.github_repo
  github_branches          = include.env.locals.github_branches
  github_environments      = include.env.locals.github_environments
  additional_iam_policies  = include.env.locals.additional_iam_policies
  create_oidc_provider     = include.env.locals.create_oidc_provider
  oidc_provider_arn        = include.env.locals.oidc_provider_arn
  max_session_duration     = include.env.locals.max_session_duration

  # Merge environment-specific tags with common tags
  common_tags = merge(
    {
      Environment = include.env.locals.environment
    },
    include.env.locals.additional_tags
  )
}
