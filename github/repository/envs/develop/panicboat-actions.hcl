locals {
  repository = {
    name        = "panicboat-actions"
    description = "Personal-use GitHub Actions wrappers for panicboat infrastructure."
    visibility  = "public"
    features = {
      issues   = true
      wiki     = false
      projects = true
    }
  }
}
