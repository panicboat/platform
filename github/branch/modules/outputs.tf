output "branch_protection_rules" {
  description = "Information about created branch protection rules"
  value = {
    for key, rule in github_branch_protection.branches : key => {
      id      = rule.id
      pattern = rule.pattern
    }
  }
}
