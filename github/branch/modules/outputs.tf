output "branch_protection_rulesets" {
  description = "Information about created repository rulesets"
  value = {
    for key, rule in github_repository_ruleset.branches : key => {
      id         = rule.id
      name       = rule.name
      repository = rule.repository
    }
  }
}
