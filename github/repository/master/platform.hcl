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
    variables = {
      APP_ID = "1371999"
    }
    secrets = {
      APP_PRIVATE_KEY = "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"
    }
  }
}
