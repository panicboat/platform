include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

terraform {
  source = "../modules"
}

inputs = {
  aws_region         = include.env.locals.aws_region
  enable_nat_gateway = false

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "vpc"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
