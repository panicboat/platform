locals {
  defaults = read_terragrunt_config("defaults.hcl")

  repository = {
    name              = "monorepo"
    branch_protection = {
      main = merge(
        local.defaults.locals.branch_protection.main,
        {
          required_status_checks = [
            "CI Gatekeeper",
            "Validate PR title",
            "Ensure actions are pinned to SHAs",
          ]
          # panicboat App (1371999) bypasses the pull_request rule for direct
          # push from Flux ImageUpdateAutomation (= release-driven image bump
          # commits to overlays/production/deployment.yaml).
          bypass_app_ids = [1371999]
        }
      )
    }
  }
}
