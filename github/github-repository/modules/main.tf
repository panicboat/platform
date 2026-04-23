# main.tf - GitHub Repository Management

# Get current AWS Account ID (used for CloudWatch logging)
data "aws_caller_identity" "current" {}

# GitHub repository basic configuration
resource "github_repository" "repository" {
  name        = var.repository_config.name
  description = var.repository_config.description
  visibility  = var.repository_config.visibility

  # Feature toggles
  has_issues   = var.repository_config.features.issues
  has_wiki     = var.repository_config.features.wiki
  has_projects = var.repository_config.features.projects

  # Security settings
  vulnerability_alerts = true

  # Merge method settings
  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = true
  allow_update_branch    = true
  allow_auto_merge       = true
  delete_branch_on_merge = true

  # Archive settings
  archived = false
}

# Branch protection rules using for_each
# Dynamically creates protection rules for all configured branches
resource "github_branch_protection" "branches" {
  for_each = var.repository_config.branch_protection

  repository_id = github_repository.repository.node_id
  pattern       = each.value.pattern != null ? each.value.pattern : each.key

  # Pull request review requirements
  required_pull_request_reviews {
    required_approving_review_count = each.value.required_reviews
    dismiss_stale_reviews           = each.value.dismiss_stale_reviews
    require_code_owner_reviews      = each.value.require_code_owner_reviews
    require_last_push_approval      = each.value.require_last_push_approval
  }

  # Status check requirements (CI/CD results)
  required_status_checks {
    strict   = false
    contexts = each.value.required_status_checks
  }

  # Admin privileges and branch operation restrictions
  enforce_admins                  = each.value.enforce_admins
  allows_force_pushes             = each.value.allow_force_pushes
  allows_deletions                = each.value.allow_deletions
  required_linear_history         = each.value.required_linear_history
  require_conversation_resolution = each.value.require_conversation_resolution
  require_signed_commits          = each.value.require_signed_commits
}

# CloudWatch Log Group for GitHub Actions (audit logging)
# Records GitHub Actions and repository event logs for monitoring and compliance
resource "aws_cloudwatch_log_group" "github_repository_logs" {
  name              = "/github-repository/${var.repository_config.name}"
  retention_in_days = var.log_retention_days

  tags = merge(var.common_tags, {
    LogGroup = "${var.project_name}-${var.repository_config.name}"
    Purpose  = "github-repository-management"
  })
}
