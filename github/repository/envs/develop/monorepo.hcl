locals {
  repository = {
    name          = "monorepo"
    description   = "Monorepo for multiple services and infrastructure configurations."
    visibility    = "public"
    allow_forking                    = false
    actions_default_permissions_read = true
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
