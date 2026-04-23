locals {
  repository = {
    name        = "platform"
    description = "Platform for multiple services and infrastructure configurations"
    visibility  = "public"
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
