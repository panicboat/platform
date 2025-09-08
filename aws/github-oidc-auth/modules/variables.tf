# variables.tf - Input variables for GitHub OIDC Auth module

variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name (develop, staging, production)"
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

variable "github_repos" {
  description = "List of GitHub repository names"
  type        = list(string)
}

variable "github_branches" {
  description = "List of GitHub branches that can assume the role"
  type        = list(string)
  default     = ["main", "master"]
}

variable "github_environments" {
  description = "List of GitHub environments that can assume the role"
  type        = list(string)
  default     = []
}

variable "additional_iam_policies" {
  description = "List of additional IAM policy ARNs to attach to the role"
  type        = list(string)
  default     = []
}

variable "max_session_duration" {
  description = "Maximum session duration for the IAM role (in seconds)"
  type        = number
  default     = 3600
  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "Max session duration must be between 900 and 43200 seconds (15 minutes to 12 hours)."
  }
}

variable "create_oidc_provider" {
  description = "Whether to create the GitHub OIDC provider (set to false if it already exists)"
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of existing GitHub OIDC provider (used when create_oidc_provider is false)"
  type        = string
  default     = ""
}
