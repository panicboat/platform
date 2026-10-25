locals {
  defaults = read_terragrunt_config("defaults.hcl")

  repository = {
    name              = ".github"
    branch_protection = {
      main = merge(
        local.defaults.locals.branch_protection.main,
        {
          required_status_checks = [
            "gatekeeper / CI Gatekeeper",
            "semantic / Validate PR title",
            "lint / Ensure actions are pinned to SHAs",
            "Test scripts",
          ]
        }
      )
    }
  }
}
