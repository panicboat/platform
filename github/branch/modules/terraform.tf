terraform {
  required_version = ">= 1.11.6"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
  }
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}
