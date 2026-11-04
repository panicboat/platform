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
  aws_region = include.env.locals.aws_region
}
