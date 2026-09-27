include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
terraform {
  source = "../..//alb/modules"
}

inputs = {
  environment = include.env.locals.environment
  aws_region  = include.env.locals.aws_region

  route53_zone_role_arn = include.env.locals.route53_zone_role_arn

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "alb"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
