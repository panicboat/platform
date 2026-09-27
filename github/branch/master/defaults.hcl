locals {
  # required_reviews = 0 allows solo self-merge because GitHub disallows approving own pull requests.
  branch_protection = {
    main = {
      name                            = null
      include_refs                    = ["~DEFAULT_BRANCH"]
      exclude_refs                    = []
      required_reviews                = 0
      dismiss_stale_reviews           = false
      require_code_owner_reviews      = false
      require_last_push_approval      = false
      require_conversation_resolution = false
      required_status_checks          = []
      strict_required_status_checks   = false
      required_linear_history         = true
      require_signed_commits          = false
      allow_force_pushes              = false
      allow_deletions                 = false
      admin_bypass                    = false
    }
  }
}
