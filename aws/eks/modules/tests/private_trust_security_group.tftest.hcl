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
      private_trust = {
        id = "sg-private-trust"
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
  environment           = "production"
  aws_region            = "ap-northeast-1"
  cluster_version       = "1.33"
  route53_zone_role_arn = "arn:aws:iam::559744160976:role/route53-zone-access"
  common_tags = {
    Environment = "production"
  }
}

run "plans_private_trust_as_additional_control_plane_security_group" {
  command = plan
}
