locals {
  repository = {
    name          = "monorepo"
    description   = "Monorepo for multiple services and infrastructure configurations."
    visibility    = "public"
    allow_forking = false
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
