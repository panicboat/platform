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
      # Ruleset name. Defaults to "<repo_key>-<rule_key>" when null.
      name = optional(string)

      # Branch selection. GitHub fileset syntax (fnmatch).
      # Use ["~DEFAULT_BRANCH"] to target the default branch only.
      include_refs = list(string)
      exclude_refs = optional(list(string), [])

      # Pull request requirements
      required_reviews                = number
      dismiss_stale_reviews           = bool
      require_code_owner_reviews      = bool
      require_last_push_approval      = bool
      require_conversation_resolution = bool

      # Status checks
      required_status_checks        = list(string)
      strict_required_status_checks = bool

      # Commit/history requirements
      required_linear_history = bool
      require_signed_commits  = bool

      # Push/delete controls
      allow_force_pushes = bool
      allow_deletions    = bool

      # When true, organization admins can bypass this ruleset.
      # Set false to enforce rules for everyone (legacy enforce_admins=true equivalent).
      admin_bypass = bool
    }))
  }))
}
