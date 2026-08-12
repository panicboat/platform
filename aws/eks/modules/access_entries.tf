# access_entries.tf - EKS Access Entries (Kubernetes RBAC mapping for IAM principals).
#
# We keep this minimal: only the human kubectl admin role is granted RBAC.
# The CI apply role (github-oidc-auth-production-github-actions-role)
# operates on AWS APIs only and never touches Kubernetes API; under the
# GitOps model, all Kubernetes-side changes flow through Flux CD.
#
# Note on policy_arn format: EKS Access Policies use a dedicated ARN
# scheme `arn:aws:eks::aws:cluster-access-policy/<NAME>`, NOT the IAM
# managed policy form `arn:aws:iam::aws:policy/<NAME>`. Passing the IAM
# form to AssociateAccessPolicy yields InvalidParameterException (400).

locals {
  access_entries = {
    human_admin = {
      principal_arn = aws_iam_role.eks_admin.arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    # OpenSRE evaluation. An LLM agent reasons over this cluster, so it gets a
    # separate principal with view-only RBAC rather than reusing the admin
    # role: the blast radius of a misbehaving agent is then bounded by IAM
    # rather than by the agent's own restraint.
    opensre = {
      principal_arn = aws_iam_role.opensre_investigator.arn

      policy_associations = {
        view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
