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

# aws_region is intentionally not passed; the module pins region to us-east-1.
inputs = {
  environment = include.env.locals.environment

  common_tags = merge(
    include.env.locals.environment_tags,
    {
      Project    = "cost-management"
      ManagedBy  = "terraform"
      Repository = "panicboat/platform"
    }
  )
}
