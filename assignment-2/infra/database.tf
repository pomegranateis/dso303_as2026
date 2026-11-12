# Amazon RDS for PostgreSQL, Multi-AZ: a synchronous standby in the second AZ.
# If the primary's AZ fails, RDS promotes the standby and moves the endpoint
# (typically 60-120 s), with no committed transaction lost. Point-in-time recovery
# from transaction logs bounds data loss for other failures to about 5 minutes.

resource "aws_db_subnet_group" "main" {
  name        = "${local.name}-db-subnets"
  description = "Data subnets in both AZs"
  subnet_ids  = aws_subnet.data[*].id
}

resource "aws_db_parameter_group" "postgres" {
  name        = "${local.name}-postgres16"
  family      = "postgres16"
  description = "TLS required, slow-query logging"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  db_name  = "exams"
  username = jsondecode(aws_secretsmanager_secret_version.db.secret_string).username
  password = random_password.db.result
  port     = 5432

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.postgres.name

  allocated_storage     = 100
  max_allocated_storage = 500
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.data.arn

  backup_retention_period         = var.db_backup_retention_days
  backup_window                   = "19:00-19:30" # 01:00-01:30 Bhutan time, outside exam hours
  maintenance_window              = "sun:20:00-sun:21:00"
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  performance_insights_enabled    = !local.floci
  auto_minor_version_upgrade      = true

  deletion_protection       = !local.floci
  skip_final_snapshot       = local.floci
  final_snapshot_identifier = local.floci ? null : "${local.name}-db-final"
  apply_immediately         = true

  # Floci does not store StorageEncrypted, KmsKeyId or the storage type, so without this
  # every plan would see "encryption changed" and replace the database. On AWS these
  # values never change after creation, so ignoring later drift loses nothing.
  lifecycle {
    ignore_changes = [storage_encrypted, kms_key_id, storage_type]
  }
}

# ---------------------------------------------------------------- RDS Proxy (AWS only)
# Thousands of concurrent Lambda environments would each hold a connection; the
# proxy multiplexes them onto a small pool and holds client connections open while
# RDS fails over, so an AZ loss looks like a pause instead of a burst of errors.

resource "aws_iam_role" "rds_proxy" {
  count = var.enable_rds_proxy ? 1 : 0
  name  = "${local.name}-rds-proxy-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "rds_proxy" {
  count = var.enable_rds_proxy ? 1 : 0
  name  = "read-db-secret"
  role  = aws_iam_role.rds_proxy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.db.arn },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = aws_kms_key.data.arn }
    ]
  })
}

resource "aws_db_proxy" "main" {
  count                  = var.enable_rds_proxy ? 1 : 0
  name                   = "${local.name}-db-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy[0].arn
  vpc_subnet_ids         = aws_subnet.app[*].id
  vpc_security_group_ids = [aws_security_group.proxy.id]
  require_tls            = true
  idle_client_timeout    = 1800

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.db.arn
  }
}

resource "aws_db_proxy_default_target_group" "main" {
  count         = var.enable_rds_proxy ? 1 : 0
  db_proxy_name = aws_db_proxy.main[0].name
  connection_pool_config {
    max_connections_percent      = 90
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "main" {
  count                  = var.enable_rds_proxy ? 1 : 0
  db_proxy_name          = aws_db_proxy.main[0].name
  target_group_name      = aws_db_proxy_default_target_group.main[0].name
  db_instance_identifier = aws_db_instance.main.identifier
}

locals {
  # Functions connect through the proxy on AWS and straight to the instance on Floci.
  db_host = var.enable_rds_proxy ? aws_db_proxy.main[0].endpoint : aws_db_instance.main.address
  # The instance endpoint is "host:port"; Floci publishes each database on its own proxy port (7001...).
  db_port = var.enable_rds_proxy ? "5432" : element(split(":", aws_db_instance.main.endpoint), 1)
}
