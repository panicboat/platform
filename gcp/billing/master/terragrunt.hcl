include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../modules"
}

inputs = {
  # The billing account is billed in JPY; 800 JPY is roughly 5 USD.
  budget_currency_code = "JPY"
  budget_amount        = 800
}
