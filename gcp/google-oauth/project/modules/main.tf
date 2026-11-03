locals {
  services = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
  ]

  member_roles = merge(
    { for member in var.owner_members : "owner/${member}" => { member = member, role = "roles/owner" } },
    { for role in ["roles/viewer", "roles/iam.securityReviewer"] : "plan/${role}" => { member = var.plan_principal, role = role } },
    { for role in ["roles/editor", "roles/resourcemanager.projectIamAdmin", "roles/serviceusage.serviceUsageAdmin"] : "apply/${role}" => { member = var.apply_principal, role = role } },
  )
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  project = var.project_id
  service = each.value

  # Terraform reaches the project through these APIs, so destroying this stack must leave them on.
  disable_on_destroy = false
}

resource "google_project_iam_member" "this" {
  for_each = local.member_roles

  project = var.project_id
  role    = each.value.role
  member  = each.value.member
}
