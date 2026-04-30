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
# the Terragrunt cache. This lets `module "vpc"` in modules/lookups.tf
# resolve `../../vpc/lookup` from within the cache. See
# docs/superpowers/specs/2026-04-29-aws-vpc-cross-stack-design.md for the
# convention.
terraform {
  source = "../../..//eks/modules"
}

# Input variables for the module
inputs = {
  environment     = include.env.locals.environment
  aws_region      = include.env.locals.aws_region
  cluster_version = include.env.locals.cluster_version

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
