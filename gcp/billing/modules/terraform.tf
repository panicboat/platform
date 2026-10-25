terraform {
  required_version = "1.13.1"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
  }
}

provider "google" {
  project = var.project_id

  # The Budget API needs a quota project, and user credentials have none by default.
  billing_project       = var.project_id
  user_project_override = true
}
