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
    database_subnet_group_name   = "vpc-production"
    nat_public_ips               = ["203.0.113.10"]
    azs                          = ["ap-northeast-1a"]
    private_route_table_ids      = ["rtb-private"]
  }
}

variables {
  environment = "production"
  aws_region  = "ap-northeast-1"
  common_tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

run "creates_private_trust_security_group" {
  command = plan

  assert {
    condition     = aws_security_group.private_trust.name == "private-trust-production"
    error_message = "The private trust security group must use the stable production name."
  }

  assert {
    condition     = (aws_vpc_security_group_ingress_rule.private_trust_self.ip_protocol == "-1" && aws_vpc_security_group_ingress_rule.private_trust_self.referenced_security_group_id == aws_security_group.private_trust.id)
    error_message = "The private trust ingress rule must allow every protocol from itself."
  }

  assert {
    condition     = (aws_vpc_security_group_egress_rule.private_trust_ipv4.ip_protocol == "-1" && aws_vpc_security_group_egress_rule.private_trust_ipv4.cidr_ipv4 == "0.0.0.0/0")
    error_message = "The private trust egress rule must allow all IPv4 destinations."
  }

  assert {
    condition     = output.private_trust_security_group_id == aws_security_group.private_trust.id
    error_message = "The producer output must expose the private trust security group ID."
  }

  assert {
    condition     = (!contains(keys(aws_security_group.private_trust.tags), "aws:eks:cluster-name") && alltrue([for key in keys(aws_security_group.private_trust.tags) : !startswith(key, "kubernetes.io/cluster/")]))
    error_message = "The private trust security group must not carry EKS discovery tags."
  }
}
