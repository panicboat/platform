locals {
  repository = {
    name = "platform"
    branch_protection = {
      main = {
        pattern                         = null
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
