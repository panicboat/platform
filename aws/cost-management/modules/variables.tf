# Retained for common_tags consistency across services though resources omit a name attribute.
variable "environment" {
  description = "Environment name (e.g., develop, production)"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
