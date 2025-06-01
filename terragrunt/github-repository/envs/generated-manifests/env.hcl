# repo.hcl - Configuration for panicboat/generated-manifests repository

locals {
  repository_config = {
    name        = "generated-manifests"
    description = "Generated Kubernetes manifests repository"
    visibility  = "public"

    # Repository features
    features = {
      issues   = true
      wiki     = false
      projects = false
    }

    # Branch protection rules
    branch_protection = {
      develop = {
        pattern                         = null # Use key as branch name
        required_reviews                = 1
        dismiss_stale_reviews           = true
        require_code_owner_reviews      = true
        restrict_pushes                 = true
        require_last_push_approval      = true
        required_status_checks          = []
        enforce_admins                  = true
        allow_force_pushes              = false
        allow_deletions                 = false
        required_linear_history         = true
        require_conversation_resolution = true
        require_signed_commits          = false
      }

      staging = {
        pattern                         = "staging"
        required_reviews                = 1
        dismiss_stale_reviews           = true
        require_code_owner_reviews      = true
        restrict_pushes                 = true
        require_last_push_approval      = true
        required_status_checks          = []
        enforce_admins                  = true
        allow_force_pushes              = false
        allow_deletions                 = false
        required_linear_history         = true
        require_conversation_resolution = true
        require_signed_commits          = false
      }

      production = {
        pattern                         = "production"
        required_reviews                = 2
        dismiss_stale_reviews           = true
        require_code_owner_reviews      = true
        restrict_pushes                 = true
        require_last_push_approval      = true
        required_status_checks          = []
        enforce_admins                  = true
        allow_force_pushes              = false
        allow_deletions                 = false
        required_linear_history         = true
        require_conversation_resolution = true
        require_signed_commits          = false
      }
    }
  }
}
