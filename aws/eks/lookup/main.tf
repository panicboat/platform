data "aws_eks_cluster" "this" {
  name = "eks-${var.environment}"
}

data "aws_caller_identity" "current" {}
