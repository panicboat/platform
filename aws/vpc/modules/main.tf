module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "vpc"
  cidr = var.vpc_cidr

  azs              = var.availability_zones
  public_subnets   = var.public_subnet_cidrs
  private_subnets  = var.private_subnet_cidrs
  database_subnets = var.database_subnet_cidrs

  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = false

  enable_ipv6            = true
  create_egress_only_igw = true

  private_subnet_ipv6_prefixes                   = [0, 1, 2]
  private_subnet_assign_ipv6_address_on_creation = true

  # DNS64 is useless without NAT64 and would hand IPv4-only hosts unroutable synthetic AAAA records.
  private_subnet_enable_dns64 = var.enable_nat_gateway

  enable_dns_support   = true
  enable_dns_hostnames = true

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  public_subnet_tags = {
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  }
  database_subnet_tags = { Tier = "database" }

  # Locks down default security group with cleared rules per CIS AWS benchmark.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []
  default_security_group_tags    = merge(var.common_tags, { Name = "default-vpc-locked" })

  tags = var.common_tags
}

# Gateway endpoint routes S3 traffic directly to avoid NAT gateway data processing charges.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(var.common_tags, {
    Name = "vpce-s3"
  })
}

resource "aws_security_group" "internal" {
  name        = "internal"
  description = "Shared trust boundary for VPC workloads"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.common_tags, {
    Name = "internal"
  })
}

resource "aws_vpc_security_group_ingress_rule" "internal_self" {
  security_group_id            = aws_security_group.internal.id
  referenced_security_group_id = aws_security_group.internal.id
  ip_protocol                  = "-1"
  description                  = "Allow traffic within the internal trust boundary"
}

resource "aws_vpc_security_group_egress_rule" "internal_ipv4" {
  security_group_id = aws_security_group.internal.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all IPv4 egress"
}

resource "aws_vpc_security_group_egress_rule" "internal_ipv6" {
  security_group_id = aws_security_group.internal.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
  description       = "Allow all IPv6 egress"
}
