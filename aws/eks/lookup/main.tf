# main.tf - Lookup of the EKS cluster by name convention `eks-${environment}`.

data "aws_eks_cluster" "this" {
  name = "eks-${var.environment}"
}

data "aws_caller_identity" "current" {}
