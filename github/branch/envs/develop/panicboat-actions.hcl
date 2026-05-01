locals {
  defaults = read_terragrunt_config("defaults.hcl")

  repository = {
    name              = "panicboat-actions"
    branch_protection = {
      main = merge(
        local.defaults.locals.branch_protection.main,
        {
          required_status_checks = [
            "Validate PR title",
            "Ensure actions are pinned to SHAs",
          ]
        }
      )
    }
  }
}
