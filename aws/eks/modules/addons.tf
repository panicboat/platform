# addons.tf - AWS-managed EKS add-ons and their IRSA roles.
#
# IRSA roles for vpc-cni and aws-ebs-csi-driver are created via the
# terraform-aws-modules/iam iam-role-for-service-accounts submodule and
# wired into the addon definitions. coredns / pod-identity-agent do not need IRSA. kube-proxy is intentionally
# omitted because Cilium is configured with kubeProxyReplacement=true (see
# kubernetes/components/cilium/production/values.yaml.gotmpl).
#
# Note on submodule naming: v5 of the IAM module shipped a dedicated
# `iam-role-for-service-accounts-eks` submodule. v6.0 renamed it to
# `iam-role-for-service-accounts` and changed the role-ARN output from
# `iam_role_arn` to `arn`. We pin `~> 6.0` and use the v6 names.

module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.6"

  name                  = "eks-${var.environment}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = var.common_tags
}

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

locals {
  cluster_addons = {
    vpc-cni = {
      # Apply vpc-cni BEFORE the node group is created so the aws-node
      # DaemonSet has its IRSA role available the moment nodes try to
      # join. Without this, nodes start without a working CNI and the
      # node group fails with NodeCreationFailure (Unhealthy nodes),
      # because the node IAM role intentionally does NOT carry
      # AmazonEKS_CNI_Policy (see node_groups.tf comment).
      before_compute              = true
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = module.vpc_cni_irsa.arn
    }
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
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
