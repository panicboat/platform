mock_provider "google" {}

variables {
  project_id      = "panicboat-test"
  owner_members   = ["user:owner@example.com"]
  plan_principal  = "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/terragrunt/attribute.aws_role/plan-role"
  apply_principal = "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/terragrunt/attribute.aws_role/apply-role"
}

run "enables_only_the_management_services" {
  command = apply

  assert {
    condition     = toset(keys(google_project_service.this)) == toset(["cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com", "iam.googleapis.com"])
    error_message = "The project must enable only the services Terraform needs to manage it."
  }

  assert {
    condition     = alltrue([for s in google_project_service.this : s.disable_on_destroy == false])
    error_message = "Destroying the stack must not disable services."
  }
}

run "keeps_the_owners" {
  command = apply

  assert {
    condition     = toset([for m in google_project_iam_member.this : m.member if m.role == "roles/owner"]) == toset(["user:owner@example.com"])
    error_message = "The owners must keep the owner role."
  }
}

run "grants_only_read_roles_to_the_plan_role" {
  command = apply

  assert {
    condition     = toset([for m in google_project_iam_member.this : m.role if m.member == var.plan_principal]) == toset(["roles/viewer", "roles/iam.securityReviewer"])
    error_message = "The plan role must get only read roles."
  }
}

run "grants_admin_roles_to_the_apply_role" {
  command = apply

  assert {
    condition     = toset([for m in google_project_iam_member.this : m.role if m.member == var.apply_principal]) == toset(["roles/editor", "roles/resourcemanager.projectIamAdmin", "roles/serviceusage.serviceUsageAdmin"])
    error_message = "The apply role must get the admin roles."
  }
}
