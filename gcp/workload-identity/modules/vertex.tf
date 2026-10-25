resource "google_iam_workload_identity_pool" "github_actions" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "github-actions"
  description               = "GitHub Actions jobs that call GCP directly"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "github"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  attribute_condition = "assertion.repository_owner == 'panicboat'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# roles/aiplatform.user also creates endpoints and jobs, which a prompt-injected run could use to run up costs.
resource "google_project_iam_custom_role" "gemini_invoker" {
  project     = var.project_id
  role_id     = "geminiInvoker"
  title       = "Gemini Invoker"
  description = "Invoke Gemini models on Vertex AI"
  permissions = ["aiplatform.endpoints.predict"]
}

resource "google_project_iam_member" "gemini" {
  for_each = toset(var.gemini_oidc_subjects)

  project = var.project_id
  role    = google_project_iam_custom_role.gemini_invoker.name
  member  = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/subject/${each.value}"
}
