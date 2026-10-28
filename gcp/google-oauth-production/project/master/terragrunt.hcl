include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../modules"
}

dependency "foundation" {
  config_path = "../../../github-actions-master/foundation/master"

  mock_outputs = {
    plan_principal  = "principalSet://iam.googleapis.com/projects/0/locations/global/workloadIdentityPools/terragrunt/attribute.aws_role/plan"
    apply_principal = "principalSet://iam.googleapis.com/projects/0/locations/global/workloadIdentityPools/terragrunt/attribute.aws_role/apply"
  }
  mock_outputs_allowed_terraform_commands = ["validate"]
}

inputs = {
  owner_members   = ["user:iam@panicboat.net"]
  plan_principal  = dependency.foundation.outputs.plan_principal
  apply_principal = dependency.foundation.outputs.apply_principal
}
