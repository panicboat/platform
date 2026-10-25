mock_provider "google" {
  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/123456789012/locations/global/workloadIdentityPools/terragrunt"
    }
  }
}

variables {
  project_id      = "panicboat-test"
  aws_account_id  = "559744160976"
  plan_role_name  = "github-oidc-auth-master-github-actions-plan-role"
  apply_role_name = "github-oidc-auth-master-github-actions-apply-role"
}

run "restricts_pool_to_master_account" {
  command = apply

  assert {
    condition     = google_iam_workload_identity_pool_provider.aws.attribute_condition == "assertion.arn.startsWith('arn:aws:sts::559744160976:assumed-role/')"
    error_message = "The provider must accept only assumed roles of the master account."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.aws.aws[0].account_id == "559744160976"
    error_message = "The provider must trust the master account."
  }
}

run "maps_the_assumed_role_name" {
  command = apply

  assert {
    condition     = google_iam_workload_identity_pool_provider.aws.attribute_mapping["attribute.aws_role"] == "assertion.arn.extract('assumed-role/{role_name}/')"
    error_message = "The provider must expose the role name as attribute.aws_role."
  }
}

run "grants_only_read_roles_to_the_plan_role" {
  command = apply

  assert {
    condition     = output.plan_principal == "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/terragrunt/attribute.aws_role/github-oidc-auth-master-github-actions-plan-role"
    error_message = "The plan principal must be the plan role of the pool."
  }

  assert {
    condition     = toset([for m in google_project_iam_member.this : m.role if m.member == output.plan_principal]) == toset(["roles/viewer", "roles/iam.securityReviewer", "roles/serviceusage.serviceUsageConsumer"])
    error_message = "The plan role must get only read roles."
  }
}

run "grants_admin_roles_to_the_apply_role" {
  command = apply

  assert {
    condition     = toset([for m in google_project_iam_member.this : m.role if m.member == output.apply_principal]) == toset(["roles/editor", "roles/resourcemanager.projectIamAdmin", "roles/iam.workloadIdentityPoolAdmin", "roles/serviceusage.serviceUsageAdmin"])
    error_message = "The apply role must get the admin roles."
  }
}

run "keeps_services_enabled_on_destroy" {
  command = apply

  assert {
    condition     = toset(keys(google_project_service.this)) == toset(["iam.googleapis.com", "sts.googleapis.com", "iamcredentials.googleapis.com", "cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com", "billingbudgets.googleapis.com"])
    error_message = "The stack must enable exactly the required services."
  }

  assert {
    condition     = alltrue([for s in google_project_service.this : s.disable_on_destroy == false])
    error_message = "Destroying the stack must not disable services."
  }
}
