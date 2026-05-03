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
# aws_region is intentionally not passed; the module pins region to us-east-1.
inputs = {
  environment = include.env.locals.environment

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "cost-management"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
