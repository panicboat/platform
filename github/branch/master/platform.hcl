locals {
  defaults = read_terragrunt_config("defaults.hcl")

  repository = {
    name = "platform"
    branch_protection = {
      main = merge(
        local.defaults.locals.branch_protection.main,
        {
          required_status_checks = [
            "ci-gatekeeper / CI Gatekeeper",
            "validate / Validate PR title",
            "ensure-sha-pinned / Ensure actions are pinned to SHAs",
          ]
        }
      )
    }
  }
}
