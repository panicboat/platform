# outputs.tf - Pass-through outputs of the underlying data sources.

output "vpc" {
  description = "VPC data source (pass-through). See AWS provider docs for aws_vpc."
  value       = data.aws_vpc.this
}

output "subnets" {
  description = "Subnets grouped by tier (pass-through of aws_subnets data sources)."
  value = {
    public   = data.aws_subnets.public
    private  = data.aws_subnets.private
    database = data.aws_subnets.database
  }
}

output "db_subnet_group" {
  description = "DB subnet group data source (pass-through). See AWS provider docs for aws_db_subnet_group."
  value       = data.aws_db_subnet_group.this
}
