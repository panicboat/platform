data "aws_caller_identity" "current" {}

locals {
  service_name = "holmesgpt"

  # Keep in sync with modelList in holmesgpt values to avoid runtime AccessDenied.
  bedrock_models = [
    "anthropic.claude-sonnet-4-6",
  ]

  # Routing targets of the `us.` profiles, per `aws bedrock get-inference-profile`.
  bedrock_profile_regions = ["us-east-1", "us-east-2", "us-west-2"]

  # Regional foundation model ARNs are required alongside inference profiles to avoid access errors.
  bedrock_invoke_resources = concat(
    [
      for m in local.bedrock_models :
      "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/us.${m}"
    ],
    flatten([
      for m in local.bedrock_models : [
        for r in local.bedrock_profile_regions :
        "arn:aws:bedrock:${r}::foundation-model/${m}"
      ]
    ]),
  )
}

# IAM role for Pod Identity Association
resource "aws_iam_role" "pod_identity" {
  name = "eks-${var.environment}-holmesgpt"

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

resource "aws_iam_role_policy" "bedrock_invoke" {
  name = "bedrock-invoke"
  role = aws_iam_role.pod_identity.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = local.bedrock_invoke_resources
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = module.eks.cluster.name
  namespace       = local.service_name
  service_account = local.service_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.common_tags
}
