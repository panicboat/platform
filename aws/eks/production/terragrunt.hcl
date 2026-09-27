include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Double-slash includes the parent directory in Terragrunt cache for relative module lookups.
terraform {
  source = "../..//eks/modules"
}

inputs = {
  environment     = include.env.locals.environment
  aws_region      = include.env.locals.aws_region
  cluster_version = include.env.locals.cluster_version

  route53_zone_role_arn = include.env.locals.route53_zone_role_arn

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "eks"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
