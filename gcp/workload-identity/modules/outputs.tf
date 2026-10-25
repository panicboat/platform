output "workload_identity_provider_name" {
  description = "Full resource name of the AWS provider, used to generate the credential configuration"
  value       = google_iam_workload_identity_pool_provider.aws.name
}

output "plan_principal" {
  description = "Principal set of the AWS plan role"
  value       = local.principals.plan
}

output "apply_principal" {
  description = "Principal set of the AWS apply role"
  value       = local.principals.apply
}

output "github_workload_identity_provider_name" {
  description = "Full resource name of the GitHub Actions provider, passed to run-gemini-cli"
  value       = google_iam_workload_identity_pool_provider.github.name
}
