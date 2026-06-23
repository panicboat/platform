terraform {
  required_version = "1.12.3"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.12"
    }
  }
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}
