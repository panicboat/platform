# addons.tf - AWS-managed EKS add-ons and their IRSA roles.
#
# IRSA roles for aws-ebs-csi-driver / cilium-operator / aws-load-balancer-controller
# / external-dns are created via the terraform-aws-modules/iam
# iam-role-for-service-accounts submodule. coredns / pod-identity-agent do
# not need IRSA. kube-proxy is intentionally omitted because Cilium is
# configured with kubeProxyReplacement=true (see
# kubernetes/components/cilium/production/values.yaml.gotmpl). vpc-cni is
# also omitted because Cilium runs in native CNI mode (ENI IPAM、Cilium が
# Pod IP allocation + datapath を全担当)、aws-node DaemonSet は不要。
#
# Note on submodule naming: v5 of the IAM module shipped a dedicated
# `iam-role-for-service-accounts-eks` submodule. v6.0 renamed it to
# `iam-role-for-service-accounts` and changed the role-ARN output from
# `iam_role_arn` to `arn`. We pin `~> 6.0` and use the v6 names.

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.6"

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
  version = "~> 6.6"

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

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.6"

  name                          = "eks-${var.environment}-external-dns"
  use_name_prefix               = false
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [module.route53.zones.panicboat_net.arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  tags = var.common_tags
}

# Cilium operator IAM role (= EKS Pod Identity Association).
#
# Cilium native CNI mode = ENI IPAM では cilium-operator が EC2 API 経由で:
# - ENI を node に attach / detach (CreateNetworkInterface / Attach... 等)
# - secondary IP を ENI に割当 / 解放 (Assign... / Unassign...)
# - tags 経由で ENI lifecycle 管理 (CreateTags / DeleteTags)
# を実行する。 必要 permission は Cilium 公式 ENI mode docs に準拠:
# https://docs.cilium.io/en/v1.19/network/concepts/ipam/eni/
#
# EKS Pod Identity Association (= eks-pod-identity-agent addon 経由) で
# `kube-system:cilium-operator` SA を本 role に紐付ける。
#
# Pod Identity 採用理由 (= 2026-05-16 cold-start bootstrap incident):
# IRSA path (= SA token → sts:AssumeRoleWithWebIdentity → cache → EC2 call) は
# 初回 STS round-trip + AWS SDK 内 retry で cilium-operator の 5 秒 hardcoded
# "initial EC2 API limits update" timeout を時に超過し crashloop となる
# (= IPAM init failure → 全 Pod IP allocate 不能 → cluster bootstrap 詰む)。
# Pod Identity は local eks-pod-identity-agent (= hostNetwork DS、 CNI 不要で
# bootstrap 後すぐ Ready) を介して credential 取得するため STS round-trip 不要、
# 5 秒 timeout 内に余裕で完了する。 karpenter sub-module も同 path を採用済。
#
# terraform-aws-modules/iam v6.6 の iam-role-for-service-accounts module は
# Pod Identity 未対応 (= oidc_providers 専用) のため、 raw aws_iam_role +
# aws_eks_pod_identity_association resource で構成。
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
      # CoreDNS Pod を system_critical MNG (= karpenter stack の bootstrap
      # MNG) に pin する。 nodeSelector + tolerations の双方が必須:
      #   - tolerations: taint `dedicated=system-critical:NoSchedule` 回避
      #     (= 同 MNG への schedule を可能にする)
      #   - nodeSelector: label `node-role/system-critical=true` で配置先を
      #     system_critical MNG に限定 (= toleration 単独では default node
      #     や Karpenter-provisioned spot にも流れうる)
      # cluster bootstrap で必須な DNS resolution を control-plane-adjacent な
      # MNG に閉じ込め、 Karpenter-provisioned node の Ready 化に依存させない。
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
    }
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }
}
