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
  description = "Map of repository ruleset configurations per repository"
  type = map(object({
    name = string
    branch_protection = map(object({
      name                            = optional(string)
      include_refs                    = list(string)
      exclude_refs                    = optional(list(string), [])
      required_reviews                = number
      dismiss_stale_reviews           = bool
      require_code_owner_reviews      = bool
      require_last_push_approval      = bool
      require_conversation_resolution = bool
      required_status_checks          = list(string)
      strict_required_status_checks   = bool
      required_linear_history         = bool
      require_signed_commits          = bool
      allow_force_pushes              = bool
      allow_deletions                 = bool
      admin_bypass                    = bool
      bypass_app_ids                  = optional(list(number), [])
    }))
  }))
}
