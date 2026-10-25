locals {
  project_id         = "panicboat-platform-github"
  billing_account_id = "01830F-ABC0AE-C3E6D2"

  # CI exchanges the assumed AWS role for GCP credentials; local runs keep the gcloud ADC.
  terraform_env_vars = get_env("GITHUB_ACTIONS", "") == "true" ? {
    GOOGLE_APPLICATION_CREDENTIALS = "${get_repo_root()}/gcp/credential-configuration.json"
  } : {}
}
