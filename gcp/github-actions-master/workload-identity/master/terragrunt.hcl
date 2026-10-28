include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../modules"
}

inputs = {
  aws_account_id  = "559744160976"
  plan_role_name  = "github-oidc-auth-master-github-actions-plan-role"
  apply_role_name = "github-oidc-auth-master-github-actions-apply-role"
}
