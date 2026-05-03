# cost_optimization_hub.tf - AWS Cost Optimization Hub enrollment

# Known issue: every plan shows a perpetual in-place update of
# include_member_accounts (state -> false) because the AWS API does not
# return this attribute on Read. Apply is idempotent and harmless.
# lifecycle.ignore_changes does not suppress this (it applies only to
# config-vs-state diffs, not refresh-driven state drift).
resource "aws_costoptimizationhub_enrollment_status" "this" {
  include_member_accounts = false
}

# aws_costoptimizationhub_preferences is intentionally NOT managed here.
# The AWS Terraform provider always sends member_account_discount_visibility
# (defaulting to "All" if unset), and the AWS API rejects that attribute
# from non-management accounts with:
#   ValidationException: Only management accounts can update member account
#   discount visibility.
# AWS defaults are used: savings_estimation_mode = "AfterDiscounts" (verified
# via "aws cost-optimization-hub get-preferences"). For a standalone account
# without enterprise discount programs, BeforeDiscounts and AfterDiscounts
# produce identical numbers.
# Add this resource back when the account becomes an Organization management
# account.
