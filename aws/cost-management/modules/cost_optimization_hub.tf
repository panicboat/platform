# cost_optimization_hub.tf - documentation only; no resources are managed.
#
# AWS Cost Optimization Hub has TWO related Terraform resources, both of
# which are unusable from this stack:
#
# 1. aws_costoptimizationhub_enrollment_status
#    The AWS API does not return include_member_accounts on Read, so refresh
#    nulls the state and every plan re-proposes "+ include_member_accounts =
#    false" with "~ status = (known after apply)". lifecycle.ignore_changes
#    (including = all) does not suppress this — provider behavior, not
#    fixable from HCL. Apply is idempotent but the perpetual diff is noise
#    that drowns out real changes.
#
# 2. aws_costoptimizationhub_preferences
#    The provider always sends member_account_discount_visibility (default
#    "All" when unset) and the AWS API rejects that attribute from
#    non-management accounts with:
#      ValidationException: Only management accounts can update member
#      account discount visibility.
#    Cannot be applied at all from a standalone account.
#
# Operational state:
# - Enrollment was performed via Terraform once (initial PR #262 / #264) and
#   the resource was subsequently `terragrunt state rm`'d to stop the
#   perpetual diff. The AWS-side enrollment remains Active permanently.
# - savings_estimation_mode is left at the AWS default "AfterDiscounts"
#   (verified via `aws cost-optimization-hub get-preferences`). For a
#   standalone account without enterprise discount programs, BeforeDiscounts
#   and AfterDiscounts produce identical numbers.
#
# Add resources back when the account becomes an Organization management
# account and the provider issues are resolved.
