variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
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

variable "repositories" {
  description = "Map of repository configurations. visibility must be one of: public, private, internal"
  type = map(object({
    name                             = string
    description                      = string
    visibility                       = string
    allow_forking                    = optional(bool, true)
    actions_default_permissions_read = optional(bool, false)
    features = object({
      issues   = bool
      wiki     = bool
      projects = bool
    })
  }))
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
