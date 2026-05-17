# main.tf - VPC composition via terraform-aws-modules/vpc/aws

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "vpc-${var.environment}"
  cidr = var.vpc_cidr

  azs              = var.availability_zones
  public_subnets   = var.public_subnet_cidrs
  private_subnets  = var.private_subnet_cidrs
  database_subnets = var.database_subnet_cidrs

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = false

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

  # Adopt the VPC default SG into Terraform state and lock it down (= ingress
  # / egress fully cleared) so that no resource accidentally inherits AWS's
  # default permissive rules. CIS Benchmark / AWS Well-Architected recommendation.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []
  default_security_group_tags    = merge(var.common_tags, { Name = "default-vpc-${var.environment}-locked" })

  tags = var.common_tags
}

# S3 Gateway VPC Endpoint
# Why: Mimir / Loki / Tempo の ingester / compactor および ECR image layer の S3 取得経路を
# NAT Gateway 経由から Gateway Endpoint 経由に切替え、NAT data processing 料金 ($0.062/GB) を回避する。
# Gateway Endpoint は時間料金もデータ処理料金も発生しない (= 完全無料)。
# 関連付け対象は private route table のみ。public は IGW 直結、database は S3 通信源ではないため除外。
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(var.common_tags, {
    Name = "vpce-s3-${var.environment}"
  })
}
