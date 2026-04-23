# variables.tf - Input variables for GitHub Repository Management module

variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Repository name (e.g., monorepo, generated-manifests)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
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

variable "repository_config" {
  description = "Repository configuration object"
  type = object({
    name        = string
    description = string
    visibility  = string

    features = object({
      issues   = bool
      wiki     = bool
      projects = bool
    })

    branch_protection = map(object({
      pattern                         = optional(string) # Pattern for branch matching (null means use key as exact branch name)
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
  })
}

variable "log_retention_days" {
  description = "CloudWatch Log Group log retention period (days)"
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653
    ], var.log_retention_days)
    error_message = "The log retention period must be a valid value in CloudWatch."
  }
}
