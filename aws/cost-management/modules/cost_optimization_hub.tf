# Resource existence indicates active status; member account enrollment is omitted to avoid plan churn.
resource "aws_costoptimizationhub_enrollment_status" "this" {}

# Preferences resource omitted to avoid perpetual plan diff from AWS API GetPreferences behavior.
