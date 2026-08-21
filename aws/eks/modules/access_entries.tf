# access_entries.tf - EKS Access Entries (Kubernetes RBAC mapping for IAM principals).
#
# We keep this minimal: the human kubectl admin role and the IAM Identity
# Center AdministratorAccess role (AWS Console EKS "Resources" tab needs an
# access entry independent of the IAM-level AWS API permissions) are
# granted RBAC. The CI apply role (github-oidc-auth-production-github-actions-role)
# operates on AWS APIs only and never touches Kubernetes API; under the
# GitOps model, all Kubernetes-side changes flow through Flux CD.
#
# Note on policy_arn format: EKS Access Policies use a dedicated ARN
# scheme `arn:aws:eks::aws:cluster-access-policy/<NAME>`, NOT the IAM
# managed policy form `arn:aws:iam::aws:policy/<NAME>`. Passing the IAM
# form to AssociateAccessPolicy yields InvalidParameterException (400).

# IAM Identity Center provisions the SSO permission-set role name with a
# random hash suffix (AWSReservedSSO_<PermissionSetName>_<hash>) that isn't
# knowable in advance, so it's looked up by name_regex instead of hardcoded.
data "aws_iam_roles" "sso_admin" {
  name_regex  = "AWSReservedSSO_AdministratorAccess_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

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

    sso_admin = {
      principal_arn = one(data.aws_iam_roles.sso_admin.arns)

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}
