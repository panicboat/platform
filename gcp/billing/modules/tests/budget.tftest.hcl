mock_provider "google" {}

variables {
  project_id           = "panicboat-test"
  billing_account_id   = "000000-000000-000000"
  budget_currency_code = "JPY"
  budget_amount        = 800
}

run "sets_the_monthly_budget" {
  command = plan

  assert {
    condition     = google_billing_budget.monthly.amount[0].specified_amount[0].currency_code == "JPY" && google_billing_budget.monthly.amount[0].specified_amount[0].units == "800"
    error_message = "The budget must use the given currency and amount."
  }
}

run "notifies_at_each_threshold" {
  command = plan

  assert {
    condition     = [for r in google_billing_budget.monthly.threshold_rules : r.threshold_percent] == [0.5, 0.9, 1.0]
    error_message = "The budget must notify at 50%, 90% and 100%."
  }
}
