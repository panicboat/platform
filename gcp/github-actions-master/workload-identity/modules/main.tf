locals {
  services = [
    "iam.googleapis.com",
    "sts.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudbilling.googleapis.com",
  ]

  role_names = {
    plan  = var.plan_role_name
    apply = var.apply_role_name
  }

  principals = {
    for kind, role_name in local.role_names :
    kind => "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.this.name}/attribute.aws_role/${role_name}"
  }

  project_roles = {
    plan = [
      "roles/viewer",
      "roles/iam.securityReviewer",
    ]
    apply = [
      "roles/editor",
      "roles/resourcemanager.projectIamAdmin",
      "roles/iam.workloadIdentityPoolAdmin",
      "roles/serviceusage.serviceUsageAdmin",
    ]
  }

  role_bindings = merge([
    for kind, roles in local.project_roles : {
      for role in roles : "${kind}/${role}" => { kind = kind, role = role }
    }
  ]...)
}

resource "google_project" "this" {
  project_id      = var.project_id
  name            = var.project_name
  org_id          = var.org_id
  billing_account = var.billing_account_id

  # The pool of this project is how CI reaches GCP, so losing the project locks CI out.
  deletion_policy     = "PREVENT"
  auto_create_network = false
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  project = google_project.this.project_id
  service = each.value

  # Other stacks rely on these APIs, so destroying this stack must leave them on.
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "this" {
  project                   = google_project.this.project_id
  workload_identity_pool_id = "terragrunt"
  display_name              = "terragrunt"
  description               = "AWS roles that run terragrunt in CI"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  project                            = google_project.this.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.this.workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-master"
  display_name                       = "aws-master"

  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.aws_role" = "assertion.arn.extract('assumed-role/{role_name}/')"
  }

  attribute_condition = "assertion.arn.startsWith('arn:aws:sts::${var.aws_account_id}:assumed-role/')"

  aws {
    account_id = var.aws_account_id
  }
}

resource "google_project_iam_member" "this" {
  for_each = local.role_bindings

  project = google_project.this.project_id
  role    = each.value.role
  member  = local.principals[each.value.kind]
}
