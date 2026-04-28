locals {
  repository = {
    name          = "platform"
    description   = "Platform for multiple services and infrastructure configurations"
    visibility    = "public"
    allow_forking = false
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
