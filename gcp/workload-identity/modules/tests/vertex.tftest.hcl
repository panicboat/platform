mock_provider "google" {
  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/123456789012/locations/global/workloadIdentityPools/github-actions"
    }
  }

  mock_resource "google_project_iam_custom_role" {
    defaults = {
      name = "projects/panicboat-test/roles/geminiInvoker"
    }
  }
}

variables {
  project_id      = "panicboat-test"
  aws_account_id  = "559744160976"
  plan_role_name  = "github-oidc-auth-master-github-actions-plan-role"
  apply_role_name = "github-oidc-auth-master-github-actions-apply-role"
  gemini_oidc_subjects = [
    "repo:panicboat/platform:environment:renovate-major-review",
    "repo:panicboat/monorepo:environment:docs-sync-check",
  ]
}

run "trusts_github_actions_of_panicboat_only" {
  command = apply

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.oidc[0].issuer_uri == "https://token.actions.githubusercontent.com"
    error_message = "The provider must trust the GitHub Actions token issuer."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository_owner == 'panicboat'"
    error_message = "The provider must accept only repositories owned by panicboat."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_mapping["google.subject"] == "assertion.sub"
    error_message = "The provider must map the OIDC subject to google.subject."
  }
}

run "lets_the_role_only_invoke_models" {
  command = apply

  assert {
    condition     = toset(google_project_iam_custom_role.gemini_invoker.permissions) == toset(["aiplatform.endpoints.predict"])
    error_message = "The custom role must only allow invoking models."
  }
}

run "grants_the_role_to_exactly_the_listed_subjects" {
  command = apply

  assert {
    condition = toset([for m in google_project_iam_member.gemini : m.member]) == toset([
      "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:panicboat/platform:environment:renovate-major-review",
      "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github-actions/subject/repo:panicboat/monorepo:environment:docs-sync-check",
    ])
    error_message = "Only the listed subjects may invoke models."
  }

  assert {
    condition     = alltrue([for m in google_project_iam_member.gemini : m.role == "projects/panicboat-test/roles/geminiInvoker"])
    error_message = "The subjects must get only the custom role."
  }
}

run "lets_the_apply_role_manage_custom_roles" {
  command = apply

  assert {
    condition     = contains([for m in google_project_iam_member.this : m.role if m.member == output.apply_principal], "roles/iam.roleAdmin")
    error_message = "The apply role must be able to manage the custom role."
  }

  assert {
    condition     = !contains([for m in google_project_iam_member.this : m.role if m.member == output.plan_principal], "roles/iam.roleAdmin")
    error_message = "The plan role must not manage roles."
  }
}

run "enables_vertex_ai" {
  command = apply

  assert {
    condition     = contains(keys(google_project_service.this), "aiplatform.googleapis.com")
    error_message = "The stack must enable Vertex AI."
  }
}
