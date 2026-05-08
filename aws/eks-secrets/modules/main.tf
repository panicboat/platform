# main.tf - EKS Secrets AWS-side infrastructure (IAM role + Pod Identity for ESO).
#
# Provides:
# 1. IAM role bound by Pod Identity Association to K8s SA
#    `external-secrets:external-secrets`
#    - AWS Secrets Manager read access (account 内全 secrets、minimum permissions)
#    - KMS Decrypt (= Secrets Manager 経由のみ、kms:ViaService condition で限定)
# 2. Pod Identity Association binding `external-secrets:external-secrets` SA → IAM role
#    - cluster_name は aws/eks/lookup module の output から取得
#
# 本 stack の outputs は helmfile values に terragrunt output 経由で渡す。

data "aws_caller_identity" "current" {}

locals {
  service_name = "external-secrets" # K8s ServiceAccount name
}

# IAM role for Pod Identity Association
resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-eso"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.common_tags
}

# IAM policy for AWS Secrets Manager read access (= minimum required)
# 2 statement: SecretsManagerRead / KmsDecryptForSecretsManager
# NOTE: Resource: "secret:*" は account 内全 secrets access。multi-team 化時に fine-grained scoping (prefix や tag-based condition) を再評価する。
resource "aws_iam_role_policy" "secrets_access" {
  name = "secrets-access"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:*"
      },
      {
        Sid    = "KmsDecryptForSecretsManager"
        Effect = "Allow"
        Action = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Pod Identity Association binding K8s SA → IAM role
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = local.service_name
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
