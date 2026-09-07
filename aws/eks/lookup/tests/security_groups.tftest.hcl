mock_provider "aws" {}

override_data {
  target = data.aws_eks_cluster.this
  values = {
    arn      = "arn:aws:eks:ap-northeast-1:337169763788:cluster/eks-production"
    endpoint = "https://eks.example.test"
    vpc_config = [{
      vpc_id                    = "vpc-test"
      cluster_security_group_id = "sg-primary"
      control_plane_egress_mode = "PRIVATE"
      endpoint_private_access   = true
      endpoint_public_access    = true
      public_access_cidrs       = ["0.0.0.0/0"]
      security_group_ids        = ["sg-primary"]
      subnet_ids                = ["subnet-a"]
    }]
    certificate_authority = [{
      data = "Y2E="
    }]
    kubernetes_network_config = [{
      elastic_load_balancing = [{
        enabled = false
      }]
      service_ipv4_cidr = "10.100.0.0/16"
      service_ipv6_cidr = null
      ip_family         = "ipv4"
    }]
    identity = [{
      oidc = [{
        issuer = "https://oidc.eks.ap-northeast-1.amazonaws.com/id/test"
      }]
    }]
  }
}

override_data {
  target = data.aws_security_group.node
  values = {
    id = "sg-module-node"
  }
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "337169763788"
  }
}

variables {
  environment = "production"
}

run "exposes_cluster_primary_security_group_id" {
  command = plan

  assert {
    condition     = output.cluster.cluster_primary_security_group_id == "sg-primary"
    error_message = "The lookup must identify the EKS-owned primary security group explicitly."
  }

  assert {
    condition     = output.cluster.cluster_security_group_id == output.cluster.cluster_primary_security_group_id
    error_message = "The compatibility field must keep its current value until consumers migrate."
  }

  assert {
    condition     = output.cluster.node_security_group_id == "sg-module-node"
    error_message = "The module node security group lookup must remain during the attachment phase."
  }
}
