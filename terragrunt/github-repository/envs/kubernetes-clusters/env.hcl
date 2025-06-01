# repo.hcl - Configuration for panicboat/kubernetes-clusters repository

locals {
  repository_config = {
    name        = "kubernetes-clusters"
    description = "Kubernetes cluster configurations"
    visibility  = "public"

    # Repository features
    features = {
      issues   = true
      wiki     = false
      projects = false
    }

    # No branch protection rules (as requested)
    branch_protection = {}
  }
}
