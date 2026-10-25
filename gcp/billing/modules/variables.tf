variable "project_id" {
  description = "GCP project ID used as the quota project of the Budget API"
  type        = string
}

variable "billing_account_id" {
  description = "Billing account ID that owns the budget"
  type        = string
}

variable "budget_currency_code" {
  description = "Currency of the billing account; the budget must use the same one"
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget in whole units of budget_currency_code"
  type        = number
}
