mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "337169763788"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "1.33.7-20250920"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  mock_resource "aws_launch_template" {
    defaults = {
      id = "lt-test"
    }
  }
}

mock_provider "cloudinit" {}

override_module {
  target = module.karpenter
  outputs = {
    node_iam_role_name = "Karpenter-eks-production"
    queue_name         = "Karpenter-eks-production"
  }
}

override_module {
  target = module.eks
  outputs = {
    cluster = {
      name                              = "eks-production"
      endpoint                          = "https://eks.example.test"
      certificate_authority_data        = "Y2E="
      service_cidr                      = "10.100.0.0/16"
      ip_family                         = "ipv4"
      cluster_security_group_id         = "sg-primary"
      cluster_primary_security_group_id = "sg-primary"
      node_security_group_id            = "sg-module-node"
    }
  }
}

override_module {
  target = module.vpc
  outputs = {
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

variables {
  environment = "production"
  aws_region  = "ap-northeast-1"
  common_tags = {
    Environment = "production"
  }
}

run "plans_primary_and_private_trust_security_groups_for_system_nodes" {
  command = plan
}
