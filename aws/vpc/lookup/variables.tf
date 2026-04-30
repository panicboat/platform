# variables.tf - Inputs for the VPC lookup module.

variable "environment" {
  description = "Environment name used to locate the VPC (matches the producer's `vpc-$${environment}` Name tag)."
  type        = string
}
