variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "github_org" {
  description = "GitHub organization name"
  type        = string
}

variable "github_token" {
  description = "GitHub personal access token"
  type        = string
  sensitive   = true
}

variable "repositories" {
  description = "Map of branch protection configurations per repository"
  type = map(object({
    name = string
    branch_protection = map(object({
      pattern                         = optional(string)
      required_reviews                = number
      dismiss_stale_reviews           = bool
      require_code_owner_reviews      = bool
      restrict_pushes                 = bool
      require_last_push_approval      = bool
      required_status_checks          = list(string)
      enforce_admins                  = bool
      allow_force_pushes              = bool
      allow_deletions                 = bool
      required_linear_history         = bool
      require_conversation_resolution = bool
      require_signed_commits          = bool
    }))
  }))
}
