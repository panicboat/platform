include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../modules"
}

inputs = {
  # The billing account is billed in JPY, so the budget is set in JPY as well.
  budget_currency_code = "JPY"
  budget_amount        = 3000
}
