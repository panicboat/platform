data "github_repository" "repo" {
  for_each = var.repositories
  name     = each.value.name
}

locals {
  rulesets = merge([
    for repo_key, repo in var.repositories : {
      for rule_key, rule in repo.branch_protection :
      "${repo_key}-${rule_key}" => {
        repository                      = data.github_repository.repo[repo_key].name
        name                            = rule.name != null ? rule.name : "${repo_key}-${rule_key}"
        include_refs                    = rule.include_refs
        exclude_refs                    = rule.exclude_refs
        required_reviews                = rule.required_reviews
        dismiss_stale_reviews           = rule.dismiss_stale_reviews
        require_code_owner_reviews      = rule.require_code_owner_reviews
        require_last_push_approval      = rule.require_last_push_approval
        require_conversation_resolution = rule.require_conversation_resolution
        required_status_checks          = rule.required_status_checks
        strict_required_status_checks   = rule.strict_required_status_checks
        required_linear_history         = rule.required_linear_history
        require_signed_commits          = rule.require_signed_commits
        allow_force_pushes              = rule.allow_force_pushes
        allow_deletions                 = rule.allow_deletions
        admin_bypass                    = rule.admin_bypass
      }
    }
  ]...)
}

resource "github_repository_ruleset" "branches" {
  for_each = local.rulesets

  name        = each.value.name
  repository  = each.value.repository
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = each.value.include_refs
      exclude = each.value.exclude_refs
    }
  }

  # Admin bypass: when true, organization admins can bypass the ruleset.
  # Leave bypass_actors empty to enforce rules for everyone (legacy enforce_admins=true equivalent).
  dynamic "bypass_actors" {
    for_each = each.value.admin_bypass ? [1] : []
    content {
      actor_id    = 5 # OrganizationAdmin
      actor_type  = "OrganizationAdmin"
      bypass_mode = "always"
    }
  }

  rules {
    # Requiring a PR effectively blocks direct pushes to the branch,
    # replacing the legacy restrict_pushes setting.
    pull_request {
      required_approving_review_count   = each.value.required_reviews
      dismiss_stale_reviews_on_push     = each.value.dismiss_stale_reviews
      require_code_owner_review         = each.value.require_code_owner_reviews
      require_last_push_approval        = each.value.require_last_push_approval
      required_review_thread_resolution = each.value.require_conversation_resolution
    }

    dynamic "required_status_checks" {
      for_each = length(each.value.required_status_checks) > 0 ? [1] : []
      content {
        strict_required_status_checks_policy = each.value.strict_required_status_checks

        dynamic "required_check" {
          for_each = each.value.required_status_checks
          content {
            context = required_check.value
          }
        }
      }
    }

    deletion                = !each.value.allow_deletions
    non_fast_forward        = !each.value.allow_force_pushes
    required_linear_history = each.value.required_linear_history
    required_signatures     = each.value.require_signed_commits
  }
}
