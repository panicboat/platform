# lookups.tf - External stack lookups.

# VPC / subnet / DB subnet group info (= database_subnet_group_name consumed
# by aws_db_instance below).
module "vpc" {
  source      = "../../vpc/lookup"
  environment = var.environment
}

# EKS cluster info (= node_security_group_id, RDS ingress source).
module "eks" {
  source      = "../../eks/lookup"
  environment = var.environment
}
