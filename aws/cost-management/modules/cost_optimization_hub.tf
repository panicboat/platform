# cost_optimization_hub.tf - AWS Cost Optimization Hub enrollment

# Workaround for hashicorp/terraform-provider-aws#39520: the
# aws_costoptimizationhub_enrollment_status resource produces a perpetual
# in-place update on every plan because the provider always plans
# include_member_accounts=false even when omitted from HCL, while the AWS
# API does not return that attribute on Read for non-management accounts.
# lifecycle.ignore_changes (including = all) does not suppress this.
#
# Workaround: invoke the AWS CLI directly via terraform_data + local-exec.
# This bypasses the broken provider resource while keeping enrollment
# managed in Terraform. The call is idempotent (re-enrolling an Active
# account is a no-op).
resource "terraform_data" "cost_optimization_hub_enrollment" {
  triggers_replace = {
    # Re-run only when this version string changes.
    version = "v1"
  }

  provisioner "local-exec" {
    command = "aws cost-optimization-hub update-enrollment-status --status Active --region us-east-1"
  }
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
