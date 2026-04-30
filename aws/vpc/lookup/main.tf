# main.tf - Tag-based discovery of VPC, subnets, and DB subnet group.

data "aws_vpc" "this" {
  tags = {
    Name = "vpc-${var.environment}"
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "public" }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "private" }
}

data "aws_subnets" "database" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "database" }
}

data "aws_db_subnet_group" "this" {
  name = "vpc-${var.environment}"
}
