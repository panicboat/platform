terraform {
  required_version = "1.13.1"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}
