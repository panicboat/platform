locals {
  repository = {
    name          = "platform"
    description   = "Platform for multiple services and infrastructure configurations"
    visibility    = "public"
    actions_default_permissions_read = true
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
    environments = { production = { deployment_tag_patterns = ["*-v*"] } }
  }
}
