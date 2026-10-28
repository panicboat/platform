variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "project_name" {
  description = "Display name of the GCP project"
  type        = string
}

variable "org_id" {
  description = "Numeric ID of the organization that owns the project"
  type        = string
}

variable "billing_account_id" {
  description = "Billing account the project is charged to"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID whose assumed roles the pool accepts"
  type        = string
}

variable "plan_role_name" {
  description = "Name of the AWS IAM role that runs terragrunt plan"
  type        = string
}

variable "apply_role_name" {
  description = "Name of the AWS IAM role that runs terragrunt apply"
  type        = string
}
