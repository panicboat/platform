data "aws_eks_cluster" "this" {
  name = "eks"
}

data "aws_caller_identity" "current" {}
