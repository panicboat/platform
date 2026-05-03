# variables.tf - Variables for cost-management module

# Cost Optimization Hub / Compute Optimizer enrollment resources do not have
# a name attribute, so this variable is not referenced in any resource block.
# Kept for consistency with sibling services and to surface env tagging via
# common_tags from root.hcl.
variable "environment" {
  description = "Environment name (e.g., develop, production)"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
