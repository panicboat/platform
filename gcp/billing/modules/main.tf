resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account_id
  display_name    = "monthly"

  amount {
    specified_amount {
      currency_code = var.budget_currency_code
      units         = tostring(var.budget_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]

    content {
      threshold_percent = threshold_rules.value
    }
  }
}
