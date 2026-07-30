# main.tf - RDS PostgreSQL for Keycloak (= toC 認証基盤の user/realm ストア).
#
# 個人運用スケール (single-AZ, db.t4g.micro) だが、EKS cluster teardown/recreate
# (docs/runbooks/eks-production-recreate.md) から独立させたいため in-cluster
# Postgres ではなく managed RDS を採用。DB subnet group は aws/vpc module が
# `create_database_subnet_group = true` で provision 済のものを再利用する。
#
# Credential は本 module が生成し AWS Secrets Manager に格納する (= Google OAuth
# のような外部 console 由来の secret と異なり、Terraform 側で完結できるため手動
# 投入にしない)。ESO IAM role (aws/eks-secrets、`secretsmanager:GetSecretValue`
# on `secret:*`) が新規 secret も自動的に read 可能、追加 IAM 変更は不要。

# =============================================================================
# Security Group: RDS ingress from EKS nodes only
# =============================================================================
resource "aws_security_group" "keycloak_db" {
  name        = "keycloak-database-${var.environment}"
  description = "Allow PostgreSQL access from EKS nodes to the Keycloak RDS instance"
  vpc_id      = module.vpc.vpc.id

  tags = merge(var.common_tags, {
    Name = "keycloak-database-${var.environment}"
  })
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_db_from_eks_nodes" {
  security_group_id            = aws_security_group.keycloak_db.id
  description                  = "PostgreSQL from EKS node security group"
  referenced_security_group_id = module.eks.cluster.node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "keycloak_db_all_egress" {
  security_group_id = aws_security_group.keycloak_db.id
  description        = "Allow all egress (= RDS management traffic)"
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol        = "-1"
}

# =============================================================================
# RDS PostgreSQL instance
# =============================================================================
resource "random_password" "db_master" {
  length  = 32
  special = false # KC_DB_PASSWORD env var 経由、記号による shell/YAML escape trouble を避ける
}

resource "aws_db_instance" "keycloak" {
  identifier     = "keycloak-${var.environment}"
  engine         = "postgres"
  engine_version = "17.4"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100 # storage autoscaling (= 突発的な user 増加に対応)
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "keycloak"
  username = "keycloak_admin"
  password = random_password.db_master.result
  port     = 5432

  db_subnet_group_name   = module.vpc.db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.keycloak_db.id]
  publicly_accessible    = false
  multi_az                = false # 個人運用スケール、コスト優先 (= 引き継ぎ: 要件顕在化時に Multi-AZ 検討)

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "keycloak-${var.environment}-final"
  apply_immediately          = false

  tags = merge(var.common_tags, {
    Name = "keycloak-${var.environment}"
  })
}

# =============================================================================
# AWS Secrets Manager: database connection info
# =============================================================================
# key 名は Kubernetes 側 (kubernetes/components/keycloak) の ExternalSecret が
# そのまま K8s Secret のキーとして 1:1 sync し、keycloakx chart の
# `extraEnvFrom` で Keycloak container に直接環境変数注入する前提 (= chart の
# `database.hostname` 等の static values は使わない、RDS endpoint は apply 時
# まで不定のため)。
resource "aws_secretsmanager_secret" "keycloak_database" {
  name = "panicboat/keycloak/database"
  tags = var.common_tags
}

resource "aws_secretsmanager_secret_version" "keycloak_database" {
  secret_id = aws_secretsmanager_secret.keycloak_database.id
  secret_string = jsonencode({
    KC_DB_URL_HOST     = aws_db_instance.keycloak.address
    KC_DB_URL_PORT     = tostring(aws_db_instance.keycloak.port)
    KC_DB_URL_DATABASE = aws_db_instance.keycloak.db_name
    KC_DB_USERNAME     = aws_db_instance.keycloak.username
    KC_DB_PASSWORD     = random_password.db_master.result
  })
}

# =============================================================================
# AWS Secrets Manager: Keycloak admin bootstrap credentials
# =============================================================================
resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "keycloak_admin" {
  name = "panicboat/keycloak/admin"
  tags = var.common_tags
}

resource "aws_secretsmanager_secret_version" "keycloak_admin" {
  secret_id = aws_secretsmanager_secret.keycloak_admin.id
  secret_string = jsonencode({
    KEYCLOAK_ADMIN          = "admin"
    KEYCLOAK_ADMIN_PASSWORD = random_password.admin.result
  })
}
