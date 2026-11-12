# AWS Backup: the long-term copy of exam records.
# Point-in-time recovery (35 days) covers the 5-minute RPO; these snapshots cover
# the 5-year retention requirement and protect against deleting the database itself.

resource "aws_backup_vault" "main" {
  name          = "${local.name}-vault"
  kms_key_arn   = aws_kms_key.data.arn
  force_destroy = local.floci
}

resource "aws_backup_plan" "records" {
  name = "${local.name}-records"

  # Floci 1.5.34 does not return backup-plan tags and cannot tag a plan by ARN.
  lifecycle {
    ignore_changes = [tags, tags_all]
  }

  rule {
    rule_name         = "daily-35-days"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 20 * * ? *)" # 02:00 Bhutan time
    lifecycle {
      delete_after = 35
    }
  }

  rule {
    rule_name         = "monthly-5-years"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 21 1 * ? *)"
    lifecycle {
      cold_storage_after = 90
      delete_after       = 1830
    }
  }
}

resource "aws_iam_role" "backup" {
  name = "${local.name}-backup-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "backup.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

# AWS managed policy; Floci 1.5.34 does not ship AWS managed policies (and evaluates none).
resource "aws_iam_role_policy_attachment" "backup" {
  count      = local.floci ? 0 : 1
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "records" {
  name         = "${local.name}-records"
  plan_id      = aws_backup_plan.records.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [aws_db_instance.main.arn]
}
