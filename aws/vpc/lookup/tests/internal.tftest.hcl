mock_provider "aws" {}

override_data {
  target = data.aws_vpc.this
  values = {
    id = "vpc-test"
  }
}

override_data {
  target = data.aws_security_group.internal
  values = {
    id   = "sg-internal"
    name = "internal"
  }
}

run "finds_internal_security_group" {
  command = plan

  assert {
    condition     = data.aws_security_group.internal.vpc_id == data.aws_vpc.this.id
    error_message = "The lookup must constrain the internal security group to the selected VPC."
  }

  assert {
    condition     = output.security_groups.internal.id == "sg-internal"
    error_message = "The lookup output must expose the internal security group data source."
  }
}
