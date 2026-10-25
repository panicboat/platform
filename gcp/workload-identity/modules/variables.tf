variable "project_id" {
  description = "GCP project ID"
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
