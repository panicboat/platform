resource "github_repository" "repository" {
  for_each = var.repositories

  name        = each.value.name
  description = each.value.description
  visibility  = each.value.visibility

  has_issues   = each.value.features.issues
  has_wiki     = each.value.features.wiki
  has_projects = each.value.features.projects

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

resource "github_repository_vulnerability_alerts" "repository" {
  for_each = var.repositories

  repository = github_repository.repository[each.key].name
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

resource "github_repository_environment" "repository" {
  for_each = merge([
    for repo_key, repo in var.repositories : {
      for env_name, env in repo.environments :
      "${repo_key}/${env_name}" => { repo_key = repo_key, name = env_name }
    }
  ]...)

  repository        = github_repository.repository[each.value.repo_key].name
  environment       = each.value.name
  can_admins_bypass = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "repository" {
  for_each = merge([
    for repo_key, repo in var.repositories : merge([
      for env_name, env in repo.environments : {
        for pattern in env.deployment_tag_patterns :
        "${repo_key}/${env_name}/${pattern}" => { env_key = "${repo_key}/${env_name}", pattern = pattern }
      }
    ]...)
  ]...)

  repository  = github_repository_environment.repository[each.value.env_key].repository
  environment = github_repository_environment.repository[each.value.env_key].environment
  tag_pattern = each.value.pattern
}
