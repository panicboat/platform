# EC2 Spot SLR is an account singleton required for Karpenter spot instances, managed here to avoid recreate churn.
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
}
