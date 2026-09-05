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
          # 1371999 = panicboat-github-workflow-bot (general CI, e.g. release-please)
          # 4671042 = panicboat-fluxcd-bot (Flux ImageUpdateAutomation direct push)
          bypass_app_ids = [1371999, 4671042]
        }
      )
    }
  }
}
