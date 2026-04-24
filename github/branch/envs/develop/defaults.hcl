locals {
  # Branch protection tuned for solo development:
  # - PR-required (no direct push to main) to guarantee CI runs
  # - required_reviews = 0 to allow self-merge (GitHub disallows self-approval)
  # - Review-related toggles disabled since there is no second reviewer
  # - Admin bypass disabled to prevent accidental direct pushes
  # - Signed commits required; local GPG/SSH signing is part of the workflow
  branch_protection = {
    main = {
      name                            = null
      include_refs                    = ["~DEFAULT_BRANCH"]
      exclude_refs                    = []
      required_reviews                = 0
      dismiss_stale_reviews           = false
      require_code_owner_reviews      = false
      require_last_push_approval      = false
      require_conversation_resolution = true
      required_status_checks          = ["CI Gatekeeper"]
      strict_required_status_checks   = false
      required_linear_history         = true
      require_signed_commits          = true
      allow_force_pushes              = false
      allow_deletions                 = false
      admin_bypass                    = false
    }
  }
}
