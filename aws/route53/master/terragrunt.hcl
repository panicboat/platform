include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
terraform {
  source = "../..//route53/modules"
}

inputs = {
  environment           = include.env.locals.environment
  aws_region            = include.env.locals.aws_region
  production_account_id = include.env.locals.production_account_id
}
