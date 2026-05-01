resource "github_repository" "repository" {
  for_each = var.repositories

  name        = each.value.name
  description = each.value.description
  visibility  = each.value.visibility

  has_issues   = each.value.features.issues
  has_wiki     = each.value.features.wiki
  has_projects = each.value.features.projects

  vulnerability_alerts = true
  allow_forking        = each.value.allow_forking

  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
  allow_update_branch    = true
  allow_auto_merge       = true
  delete_branch_on_merge = true

  squash_merge_commit_message = "BLANK"
  squash_merge_commit_title   = "PR_TITLE"

  archived = false
}

resource "github_workflow_repository_permissions" "repository" {
  for_each = {
    for k, v in var.repositories :
    k => v if v.actions_default_permissions_read
  }

  repository                       = github_repository.repository[each.key].name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}

resource "aws_cloudwatch_log_group" "github_repository_logs" {
  for_each = var.repositories

  name              = "/github-repository/${each.value.name}"
  retention_in_days = var.log_retention_days

  tags = merge(var.common_tags, {
    LogGroup = "${var.project_name}-${each.value.name}"
    Purpose  = "github-repository-management"
  })
}
