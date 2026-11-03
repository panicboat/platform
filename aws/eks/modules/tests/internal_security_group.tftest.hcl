mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "337169763788"
      arn        = "arn:aws:iam::337169763788:user/test"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::337169763788:role/eks-test"
    }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      identity = [{
        oidc = [{
          issuer = "https://oidc.eks.ap-northeast-1.amazonaws.com/id/test"
        }]
      }]
      certificate_authority = [{
        data = "Y2E="
      }]
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::337169763788:policy/test"
    }
  }
}

mock_provider "time" {}
mock_provider "tls" {}

override_module {
  target = module.vpc
  outputs = {
    vpc = {
      id = "vpc-test"
    }
    subnets = {
      private = {
        ids = ["subnet-a", "subnet-b"]
      }
    }
    security_groups = {
      internal = {
        id = "sg-internal"
      }
    }
  }
}

override_data {
  target = data.aws_iam_roles.sso_admin
  values = {
    arns = ["arn:aws:iam::337169763788:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_test"]
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "337169763788"
  }
}

variables {
  aws_region            = "ap-northeast-1"
  cluster_version       = "1.33"
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"
  common_tags = {
    Environment = "production"
  }
}

run "uses_internal_for_cluster_and_node_security_groups" {
  command = plan

  assert {
    condition     = module.eks.cluster_security_group_id == null
    error_message = "The EKS module must not create a cluster security group."
  }

  assert {
    condition     = module.eks.node_security_group_id == null
    error_message = "The EKS module must not create a node security group."
  }

}

run "names_cluster_and_roles_without_environment" {
  command = plan

  assert {
    condition     = module.eks.cluster_name == "eks"
    error_message = "The cluster must be named eks."
  }

  assert {
    condition     = aws_iam_role.eks_admin.name == "eks-admin"
    error_message = "The admin role must be named eks-admin."
  }

  assert {
    condition     = module.alb_controller_irsa.name == "eks-alb-controller"
    error_message = "The ALB controller role must be named eks-alb-controller."
  }

  assert {
    condition     = module.external_dns_irsa.name == "eks-external-dns"
    error_message = "The external-dns role must be named eks-external-dns."
  }

  assert {
    condition     = aws_iam_role.cilium_operator.name == "eks-cilium-operator"
    error_message = "The Cilium operator role must be named eks-cilium-operator."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.eks_admin_describe_cluster.policy).Statement[0].Resource == "arn:aws:eks:ap-northeast-1:337169763788:cluster/eks"
    error_message = "The admin policy must target the cluster named eks."
  }
}
