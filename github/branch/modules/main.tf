data "github_repository" "repo" {
  for_each = var.repositories
  name     = each.value.name
}

locals {
  branch_protection_rules = merge([
    for repo_key, repo in var.repositories : {
      for branch_key, branch in repo.branch_protection :
      "${repo_key}-${branch_key}" => {
        repository_node_id              = data.github_repository.repo[repo_key].node_id
        pattern                         = branch.pattern != null ? branch.pattern : branch_key
        required_reviews                = branch.required_reviews
        dismiss_stale_reviews           = branch.dismiss_stale_reviews
        require_code_owner_reviews      = branch.require_code_owner_reviews
        require_last_push_approval      = branch.require_last_push_approval
        required_status_checks          = branch.required_status_checks
        enforce_admins                  = branch.enforce_admins
        allow_force_pushes              = branch.allow_force_pushes
        allow_deletions                 = branch.allow_deletions
        required_linear_history         = branch.required_linear_history
        require_conversation_resolution = branch.require_conversation_resolution
        require_signed_commits          = branch.require_signed_commits
        # TODO: restrict_pushes is accepted in variables but not yet applied.
        # GitHub Provider v6 uses push_restrictions block — implement when needed.
      }
    }
  ]...)
}

resource "github_branch_protection" "branches" {
  for_each = local.branch_protection_rules

  repository_id = each.value.repository_node_id
  pattern       = each.value.pattern

  required_pull_request_reviews {
    required_approving_review_count = each.value.required_reviews
    dismiss_stale_reviews           = each.value.dismiss_stale_reviews
    require_code_owner_reviews      = each.value.require_code_owner_reviews
    require_last_push_approval      = each.value.require_last_push_approval
  }

  required_status_checks {
    strict   = false
    contexts = each.value.required_status_checks
  }

  enforce_admins                  = each.value.enforce_admins
  allows_force_pushes             = each.value.allow_force_pushes
  allows_deletions                = each.value.allow_deletions
  required_linear_history         = each.value.required_linear_history
  require_conversation_resolution = each.value.require_conversation_resolution
  require_signed_commits          = each.value.require_signed_commits
}
