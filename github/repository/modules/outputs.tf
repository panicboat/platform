output "repository_ids" {
  description = "GitHub repository IDs"
  value       = { for k, v in github_repository.repository : k => v.repo_id }
}

output "repository_node_ids" {
  description = "GitHub repository node IDs"
  value       = { for k, v in github_repository.repository : k => v.node_id }
}

output "repository_full_names" {
  description = "Full names of the repositories (org/repo)"
  value       = { for k, v in github_repository.repository : k => v.full_name }
}

output "repository_html_urls" {
  description = "URLs to the repositories on GitHub"
  value       = { for k, v in github_repository.repository : k => v.html_url }
}

output "repository_http_clone_urls" {
  description = "URLs for cloning repositories via HTTPS"
  value       = { for k, v in github_repository.repository : k => v.http_clone_url }
}

output "repository_ssh_clone_urls" {
  description = "URLs for cloning repositories via SSH"
  value       = { for k, v in github_repository.repository : k => v.ssh_clone_url }
}
