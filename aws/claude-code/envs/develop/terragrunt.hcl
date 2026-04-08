# terragrunt.hcl - Terragrunt configuration for develop environment

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
  project_name = "claude-code"
  environment  = include.env.locals.environment

  # AWS configuration
  aws_region          = include.env.locals.aws_region
  claude_model_region = include.env.locals.claude_model_region

  # Trust configuration
  trusted_principal_arns = include.env.locals.trusted_principal_arns

  # IAM configuration
  max_session_duration    = include.env.locals.max_session_duration
  additional_iam_policies = include.env.locals.additional_iam_policies

  # Tags
  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "claude-code"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
