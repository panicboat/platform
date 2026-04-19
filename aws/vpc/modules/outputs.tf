# outputs.tf - Outputs for the VPC module

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of the private (compute) subnets"
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "IDs of the isolated database subnets"
  value       = module.vpc.database_subnets
}

output "public_subnet_cidrs" {
  description = "CIDR blocks of the public subnets"
  value       = module.vpc.public_subnets_cidr_blocks
}

output "private_subnet_cidrs" {
  description = "CIDR blocks of the private (compute) subnets"
  value       = module.vpc.private_subnets_cidr_blocks
}

output "database_subnet_cidrs" {
  description = "CIDR blocks of the isolated database subnets"
  value       = module.vpc.database_subnets_cidr_blocks
}

output "database_subnet_group_name" {
  description = "Name of the DB subnet group (for RDS module consumers)"
  value       = module.vpc.database_subnet_group_name
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT Gateway(s). Use for IP allowlisting against egress traffic."
  value       = module.vpc.nat_public_ips
}

output "availability_zones" {
  description = "Availability zones used by the VPC"
  value       = module.vpc.azs
}
