# compute_optimizer.tf - AWS Compute Optimizer enrollment

resource "aws_computeoptimizer_enrollment_status" "this" {
  status                  = "Active"
  include_member_accounts = false
}
