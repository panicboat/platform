# repo.hcl - Configuration for panicboat/monorepo repository

locals {
  repository_config = {
    name        = "monorepo"
    description = "Monorepo for multiple services and infrastructure configurations"
    visibility  = "public"

    # Repository features
    features = {
      issues   = true
      wiki     = false
      projects = true
    }

    # Branch protection rules
    branch_protection = {
      main = {
        required_reviews                = 0
        dismiss_stale_reviews           = true
        require_code_owner_reviews      = false
        restrict_pushes                 = true
        require_last_push_approval      = false
        required_status_checks          = ["CI Gatekeeper"]
        enforce_admins                  = false
        allow_force_pushes              = false
        allow_deletions                 = false
        required_linear_history         = true
        require_conversation_resolution = true
        require_signed_commits          = false
      }
    }
  }
}
