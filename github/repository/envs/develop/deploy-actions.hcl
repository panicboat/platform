locals {
  repository = {
    name        = "deploy-actions"
    description = "Generic deployment orchestration toolkit for multi-service GitHub Actions workflows."
    visibility  = "public"
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
