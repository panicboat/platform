locals {
  defaults = read_terragrunt_config("defaults.hcl")

  repository = {
    name              = "monorepo"
    branch_protection = local.defaults.locals.branch_protection
  }
}
