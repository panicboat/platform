include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../modules"
}

dependency "workload_identity" {
  config_path = "../../../github-actions-master/workload-identity/master"

  mock_outputs = {
    plan_principal  = "principalSet://iam.googleapis.com/projects/0/locations/global/workloadIdentityPools/terragrunt/attribute.aws_role/plan"
    apply_principal = "principalSet://iam.googleapis.com/projects/0/locations/global/workloadIdentityPools/terragrunt/attribute.aws_role/apply"
  }
  mock_outputs_allowed_terraform_commands = ["validate"]
}

inputs = {
  owner_members   = ["user:iam@panicboat.net"]
  plan_principal  = dependency.workload_identity.outputs.plan_principal
  apply_principal = dependency.workload_identity.outputs.apply_principal
}
