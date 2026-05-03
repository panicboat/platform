# cost_optimization_hub.tf - AWS Cost Optimization Hub enrollment and preferences

resource "aws_costoptimizationhub_enrollment_status" "this" {
  include_member_accounts = false
}

resource "aws_costoptimizationhub_preferences" "this" {
  savings_estimation_mode            = "BeforeDiscounts"
  member_account_discount_visibility = "None"

  depends_on = [aws_costoptimizationhub_enrollment_status.this]
}
