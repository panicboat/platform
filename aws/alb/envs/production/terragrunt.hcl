# terragrunt.hcl - Terragrunt configuration for production environment

# Include root configuration
include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Include environment-specific configuration
include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "route53"` in modules/lookups.tf
# resolve `../../route53/lookup` from within the cache.
terraform {
  source = "../../..//alb/modules"
}

# Input variables for the module
inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "alb"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
