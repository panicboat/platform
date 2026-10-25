locals {
  defaults = read_terragrunt_config("defaults.hcl")

  repository = {
    name              = "monorepo"
    branch_protection = {
      main = merge(
        local.defaults.locals.branch_protection.main,
        {
          required_status_checks = [
            "ci-gatekeeper / CI Gatekeeper",
            "validate / Validate PR title",
            "ensure-sha-pinned / Ensure actions are pinned to SHAs",
            "Docs Sync Check",
          ]
          # Allows release and image update bots to push directly without failing status checks.
          bypass_app_ids = [1371999, 4671042]
        }
      )
    }
  }
}
