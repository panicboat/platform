mock_provider "aws" {}

override_data {
  target = data.aws_vpc.this
  values = {
    id = "vpc-test"
  }
}

override_data {
  target = data.aws_security_group.private_trust
  values = {
    id   = "sg-private-trust"
    name = "private-trust-production"
  }
}

variables {
  environment = "production"
}

run "finds_private_trust_security_group" {
  command = plan

  assert {
    condition     = data.aws_security_group.private_trust.vpc_id == data.aws_vpc.this.id
    error_message = "The lookup must constrain the private trust security group to the selected VPC."
  }

  assert {
    condition     = output.security_groups.private_trust.id == "sg-private-trust"
    error_message = "The lookup output must expose the private trust security group data source."
  }
}
