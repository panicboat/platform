# variables.tf - Variables for Claude Code Action module

variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., development, staging, production)"
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

variable "github_repos" {
  description = "List of GitHub repository names"
  type        = list(string)
  default     = ["monorepo"]
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "oidc_provider_arn" {
  description = "ARN of existing OIDC provider"
  type        = string
}

variable "max_session_duration" {
  description = "Maximum session duration for the IAM role (in seconds)"
  type        = number
  default     = 3600
  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "Max session duration must be between 3600 (1 hour) and 43200 (12 hours) seconds."
  }
}

variable "additional_iam_policies" {
  description = "List of additional IAM policy ARNs to attach to the role"
  type        = list(string)
  default     = []
}

variable "bedrock_models" {
  description = "List of Bedrock Claude model IDs to allow access to"
  type        = list(string)
  default = [
    "anthropic.claude-3-7-sonnet-20250219-v1:0"
  ]
}


variable "claude_model_region" {
  description = "AWS region where Claude models are available (may differ from main region)"
  type        = string
  default     = "us-west-2"
}
