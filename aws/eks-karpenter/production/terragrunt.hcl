include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Double-slash includes the parent directory in Terragrunt cache for relative module lookups.
terraform {
  source = "../..//eks-karpenter/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks-karpenter"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
