locals {
  defaults = read_terragrunt_config("defaults.hcl")

  repository = {
    name              = "deploy-actions"
    branch_protection = local.defaults.locals.branch_protection
  }
}
