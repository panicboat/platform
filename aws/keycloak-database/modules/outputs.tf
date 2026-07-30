# outputs.tf - Outputs for the keycloak-database module.

output "db_instance_identifier" {
  description = "RDS instance identifier. Used for verification (aws rds describe-db-instances)."
  value       = aws_db_instance.keycloak.identifier
}

output "db_instance_endpoint" {
  description = "RDS instance endpoint (host:port)."
  value       = aws_db_instance.keycloak.endpoint
}

output "database_secret_arn" {
  description = "ARN of the Secrets Manager secret holding DB connection info (panicboat/keycloak/database)."
  value       = aws_secretsmanager_secret.keycloak_database.arn
}

output "admin_secret_arn" {
  description = "ARN of the Secrets Manager secret holding Keycloak admin bootstrap credentials (panicboat/keycloak/admin)."
  value       = aws_secretsmanager_secret.keycloak_admin.arn
}
