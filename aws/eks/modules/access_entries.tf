# access_entries.tf - EKS Access Entries (Kubernetes RBAC mapping for IAM principals).
#
# We keep this minimal: only the human kubectl admin role is granted RBAC.
# The CI apply role (github-oidc-auth-production-github-actions-role)
# operates on AWS APIs only and never touches Kubernetes API; under the
# GitOps model, all Kubernetes-side changes flow through Flux CD.

locals {
  access_entries = {
    human_admin = {
      principal_arn = aws_iam_role.eks_admin.arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
