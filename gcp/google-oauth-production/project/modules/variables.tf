variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "owner_members" {
  description = "Members that keep the owner role of the project"
  type        = list(string)
}

variable "plan_principal" {
  description = "Principal set of the AWS plan role"
  type        = string
}

variable "apply_principal" {
  description = "Principal set of the AWS apply role"
  type        = string
}
