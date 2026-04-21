# variables.tf - Variables for bedrock-claude module

variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., develop, staging, production)"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "trusted_principal_arns" {
  description = "List of AWS principal ARNs allowed to assume the CLI role"
  type        = list(string)
}

variable "github_org" {
  description = "GitHub organization name"
  type        = string
}

variable "github_repos" {
  description = "List of GitHub repository names"
  type        = list(string)
  default     = []
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
  description = "List of additional IAM policy ARNs to attach to both roles"
  type        = list(string)
  default     = []
}

variable "bedrock_inference_profiles" {
  description = "List of Bedrock cross-region inference profiles to allow access to. Each entry defines the inference profile ID, the underlying foundation model ID, and the source regions the profile routes to."
  type = list(object({
    profile_id     = string
    model_id       = string
    source_regions = list(string)
  }))
  default = [
    {
      profile_id = "us.anthropic.claude-sonnet-4-6"
      model_id   = "anthropic.claude-sonnet-4-6"
      source_regions = [
        "us-east-1",
        "us-east-2",
      ]
    },
    {
      profile_id = "us.anthropic.claude-opus-4-7"
      model_id   = "anthropic.claude-opus-4-7"
      source_regions = [
        "us-east-1",
        "us-east-2",
      ]
    },
    {
      profile_id = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
      model_id   = "anthropic.claude-haiku-4-5-20251001-v1:0"
      source_regions = [
        "us-east-1",
        "us-east-2",
      ]
    },
  ]
}

variable "claude_model_region" {
  description = "AWS region where Claude models are available (may differ from main region)"
  type        = string
  default     = "us-west-2"
}
