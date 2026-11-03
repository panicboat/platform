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
  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-system-critical-az"]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = {
      id = "lt-test"
    }
  }
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:ap-northeast-1:337169763788:queue"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::337169763788:role/role"
    }
  }
}

mock_provider "cloudinit" {}

override_module {
  target = module.eks
  outputs = {
    cluster = {
      name                              = "eks"
      endpoint                          = "https://eks.example.test"
      certificate_authority_data        = "Y2E="
      service_cidr                      = "10.100.0.0/16"
      ip_family                         = "ipv4"
      cluster_primary_security_group_id = "sg-primary"
    }
  }
}

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

variables {
  aws_region = "ap-northeast-1"
  common_tags = {
    Environment = "production"
  }
}

run "plans_primary_and_internal_security_groups_for_system_nodes" {
  command = plan
}

run "names_karpenter_and_system_critical_resources" {
  command = plan

  assert {
    condition     = output.node_role_name == "Karpenter-eks"
    error_message = "The Karpenter node role must be named Karpenter-eks."
  }

  assert {
    condition     = output.interruption_queue_name == "Karpenter-eks"
    error_message = "The interruption queue must be named Karpenter-eks."
  }

  assert {
    condition     = module.system_critical.iam_role_name == "eks-system-critical-eks-node-group"
    error_message = "The system-critical node group name must be eks-system-critical."
  }
}
