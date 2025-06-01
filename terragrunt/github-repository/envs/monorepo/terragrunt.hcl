# terragrunt.hcl - Terragrunt configuration for panicboat/monorepo repository

# Include root configuration
include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Include environment-specific configuration
include "env" {
  path   = "env.hcl"
  expose = true
}

# Terraform module source
terraform {
  source = "../../modules"
}

# Repository-specific inputs
inputs = {
  repository_config = include.env.locals.repository_config
  github_token      = get_env("GITHUB_TOKEN", "")
}
