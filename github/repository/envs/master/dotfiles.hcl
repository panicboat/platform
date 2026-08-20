locals {
  repository = {
    name        = "dotfiles"
    description = ""
    visibility  = "public"
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
