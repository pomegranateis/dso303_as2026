# Three buckets, all private with every public-access block on:
#   frontend - the single-page app, read only by CloudFront (origin access control)
#   uploads  - assignment files: versioned, SSE-KMS, lifecycle to cheaper tiers, kept 5 years
#   logs     - CloudTrail and access logs, kept 5 years

resource "aws_s3_bucket" "frontend" {
  bucket        = "${local.name}-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = local.floci
}

resource "aws_s3_bucket" "uploads" {
  bucket        = "${local.name}-uploads-${data.aws_caller_identity.current.account_id}"
  force_destroy = local.floci
}

resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name}-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = local.floci
}

resource "aws_s3_bucket_public_access_block" "all" {
  for_each                = { frontend = aws_s3_bucket.frontend.id, uploads = aws_s3_bucket.uploads.id, logs = aws_s3_bucket.logs.id }
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "all" {
  for_each = { frontend = aws_s3_bucket.frontend.id, uploads = aws_s3_bucket.uploads.id, logs = aws_s3_bucket.logs.id }
  bucket   = each.value
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend_logs" {
  for_each = { frontend = aws_s3_bucket.frontend.id, logs = aws_s3_bucket.logs.id }
  bucket   = each.value
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Records kept for 5 years, getting cheaper as they age:
# Standard -> Standard-IA (30 d) -> Glacier Instant Retrieval (180 d) -> Deep Archive (1 y) -> deleted (5 y).
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "submissions-5-year-retention"
    status = "Enabled"
    filter {
      prefix = "submissions/"
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 180
      storage_class = "GLACIER_IR"
    }
    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }
    expiration {
      days = 1830
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "logs-5-year-retention"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 1830
    }
  }
}

# Browsers POST uploads straight to S3 with a presigned form, so the bucket must allow
# cross-origin POST from the app's own origin (and nothing else).
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  cors_rule {
    allowed_methods = ["POST", "GET"]
    allowed_origins = local.floci ? ["http://localhost:4566"] : ["https://${coalesce(var.domain_name, one(aws_cloudfront_distribution.main[*].domain_name))}"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# Encryption in transit: refuse any request to the uploads bucket that is not TLS.
resource "aws_s3_bucket_policy" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.uploads.arn, "${aws_s3_bucket.uploads.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.all]
}

# ObjectCreated -> SQS (not straight to Lambda): the queue absorbs a deadline-night burst
# of uploads and keeps failed events in a dead-letter queue instead of losing them.
resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  queue {
    queue_arn     = aws_sqs_queue.work["uploads"].arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "submissions/"
  }
  depends_on = [aws_sqs_queue_policy.uploads]
}
