mock_provider "aws" {}

override_module {
  target = module.vpc
  outputs = {
    vpc_id                       = "vpc-test"
    vpc_cidr_block               = "10.0.0.0/16"
    public_subnets               = ["subnet-public"]
    private_subnets              = ["subnet-private"]
    database_subnets             = ["subnet-database"]
    public_subnets_cidr_blocks   = ["10.0.0.0/24"]
    private_subnets_cidr_blocks  = ["10.0.32.0/19"]
    database_subnets_cidr_blocks = ["10.0.10.0/24"]
    database_subnet_group_name   = "vpc"
    nat_public_ips               = ["203.0.113.10"]
    azs                          = ["ap-northeast-1a"]
    private_route_table_ids      = ["rtb-private"]
  }
}

variables {
  aws_region         = "ap-northeast-1"
  enable_nat_gateway = false
  common_tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

run "creates_internal_security_group" {
  command = plan

  assert {
    condition     = aws_security_group.internal.name == "internal"
    error_message = "The internal security group must use the stable name internal."
  }

  assert {
    condition     = aws_security_group.internal.tags["Name"] == "internal"
    error_message = "The internal security group must carry the Name tag internal."
  }

  assert {
    condition     = (aws_vpc_security_group_ingress_rule.internal_self.ip_protocol == "-1" && aws_vpc_security_group_ingress_rule.internal_self.referenced_security_group_id == aws_security_group.internal.id)
    error_message = "The internal ingress rule must allow every protocol from itself."
  }

  assert {
    condition     = (aws_vpc_security_group_egress_rule.internal_ipv4.ip_protocol == "-1" && aws_vpc_security_group_egress_rule.internal_ipv4.cidr_ipv4 == "0.0.0.0/0")
    error_message = "The internal egress rule must allow all IPv4 destinations."
  }

  assert {
    condition     = (aws_vpc_security_group_egress_rule.internal_ipv6.ip_protocol == "-1" && aws_vpc_security_group_egress_rule.internal_ipv6.cidr_ipv6 == "::/0")
    error_message = "The internal egress rule must allow all IPv6 destinations."
  }

  assert {
    condition     = output.internal_security_group_id == aws_security_group.internal.id
    error_message = "The producer output must expose the internal security group ID."
  }

  assert {
    condition     = (!contains(keys(aws_security_group.internal.tags), "aws:eks:cluster-name") && alltrue([for key in keys(aws_security_group.internal.tags) : !startswith(key, "kubernetes.io/cluster/")]))
    error_message = "The internal security group must not carry EKS discovery tags."
  }
}

run "network_has_ipv6_egress_without_nat" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.s3.tags["Name"] == "vpce-s3"
    error_message = "The S3 gateway endpoint must carry the Name tag vpce-s3."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.route_table_ids == toset(["rtb-private"])
    error_message = "The S3 gateway endpoint must attach to the private route tables."
  }
}
