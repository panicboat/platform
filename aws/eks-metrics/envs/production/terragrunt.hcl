# terragrunt.hcl - Terragrunt configuration for production environment

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
# Use go-getter `//` subdir notation so the entire `aws/` tree is copied to
# the Terragrunt cache. This lets `module "eks"` in modules/lookups.tf
# resolve `../../eks/lookup` from within the cache.
terraform {
  source = "../../..//eks-metrics/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks-metrics"
      ManagedBy  = "terragrunt"
      Repository = "panicboat/platform"
    }
  )
}
