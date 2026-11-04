include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "env" {
  path   = "env.hcl"
  expose = true
}

# Reference to Terraform modules.
terraform {
  source = "../..//eks-logs/modules"
}

inputs = {
  aws_region = include.env.locals.aws_region
}
