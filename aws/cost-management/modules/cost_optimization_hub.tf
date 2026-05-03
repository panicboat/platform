# cost_optimization_hub.tf - AWS Cost Optimization Hub enrollment and preferences

resource "aws_costoptimizationhub_enrollment_status" "this" {
  include_member_accounts = false
}

# member_account_discount_visibility is intentionally omitted: the AWS API
# rejects this attribute for non-management accounts with
# "Only management accounts can update member account discount visibility."
# Add it back when this account becomes an Organization management account.
resource "aws_costoptimizationhub_preferences" "this" {
  savings_estimation_mode = "BeforeDiscounts"

  depends_on = [aws_costoptimizationhub_enrollment_status.this]
}
