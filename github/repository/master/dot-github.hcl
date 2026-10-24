locals {
  repository = {
    name        = ".github"
    description = "Default community health files and shared GitHub workflows for panicboat repositories."
    visibility  = "public"
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
