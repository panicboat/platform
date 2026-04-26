locals {
  defaults = read_terragrunt_config("defaults.hcl")

  repository = {
    name              = "platform"
    branch_protection = {
      main = merge(
        local.defaults.locals.branch_protection.main,
        {
          required_status_checks = ["CI Gatekeeper"]
        }
      )
    }
  }
}
