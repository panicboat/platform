module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name                  = "eks-${var.environment}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = var.common_tags
}

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name                                   = "eks-${var.environment}-alb-controller"
  use_name_prefix                        = false
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = var.common_tags
}

# Assumes cross-account role to update hosted zones residing in management account.
data "aws_iam_policy_document" "external_dns_assume_zone_access" {
  statement {
    actions   = ["sts:AssumeRole"]
    resources = [var.route53_zone_role_arn]
  }
}

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name            = "eks-${var.environment}-external-dns"
  use_name_prefix = false

  source_policy_documents = [data.aws_iam_policy_document.external_dns_assume_zone_access.json]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  tags = var.common_tags
}

# Pod Identity avoids STS round-trips exceeding cilium-operator 5-second startup timeout.
data "aws_iam_policy_document" "cilium_operator_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cilium_operator" {
  name               = "eks-${var.environment}-cilium-operator"
  assume_role_policy = data.aws_iam_policy_document.cilium_operator_assume.json
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "cilium_operator" {
  name = "cilium-operator"
  role = aws_iam_role.cilium_operator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRouteTables",
          "ec2:DescribeTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2ENIManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:AttachNetworkInterface",
          "ec2:DetachNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2TagManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "cilium_operator" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "cilium-operator"
  role_arn        = aws_iam_role.cilium_operator.arn
}

locals {
  cluster_addons = {
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      # Pins CoreDNS to system_critical nodes so DNS resolution does not depend on dynamic Karpenter nodes.
      configuration_values = jsonencode({
        nodeSelector = {
          "node-role/system-critical" = "true"
        }
        tolerations = [
          {
            key      = "dedicated"
            operator = "Equal"
            value    = "system-critical"
            effect   = "NoSchedule"
          }
        ]
      })
    }
    aws-ebs-csi-driver = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = module.ebs_csi_irsa.arn

      # Disables snapshotter sidecar because VolumeSnapshot CRDs are uninstalled.
      configuration_values = jsonencode({
        controller = {
          extraVolumeTags = {
            ManagedBy = "aws-ebs-csi-driver"
          }
        }
        sidecars = {
          snapshotter = {
            forceEnable = false
          }
        }
      })
    }
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }
}
