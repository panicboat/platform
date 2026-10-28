locals {
  # CI exchanges the assumed AWS role for GCP credentials; local runs keep the gcloud ADC.
  terraform_env_vars = get_env("GITHUB_ACTIONS", "") == "true" ? {
    GOOGLE_APPLICATION_CREDENTIALS = "${get_repo_root()}/gcp/credential-configuration.json"
  } : {}
}
