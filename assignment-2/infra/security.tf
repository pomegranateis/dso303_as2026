# Customer-managed KMS key for data at rest: RDS, S3 uploads, Secrets Manager,
# CloudWatch Logs and the backup vault. Rotated yearly.
resource "aws_kms_key" "data" {
  description             = "${local.name} data at rest"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "data" {
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

# Database master credentials: generated here, stored only in Secrets Manager,
# read at runtime by the functions (and by RDS Proxy on AWS).
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#%^*-_=+"
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/db/master"
  description             = "PostgreSQL master credentials for ${local.name}-db"
  kms_key_id              = aws_kms_key.data.arn
  recovery_window_in_days = local.floci ? 0 : 30
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "examadmin"
    password = random_password.db.result
    engine   = "postgres"
    dbname   = "exams"
  })
}
