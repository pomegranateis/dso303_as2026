# Four Lambda functions (Python 3.12). Three need the database and run in the
# private app subnets of both AZs; the notifier needs no VPC access.

locals {
  functions = {
    exam_api = {
      description = "Exam platform API (walkthroughs 1 and 2)"
      memory      = 1024
      timeout     = 15
      vpc         = true
    }
    submission_processor = {
      description = "Validates uploaded files and announces SubmissionReceived"
      memory      = 512
      timeout     = 20
      vpc         = true
    }
    auto_marker = {
      description = "Marks MCQs and fans out result e-mails"
      memory      = 512
      timeout     = 60
      vpc         = true
    }
    notifier = {
      description = "Sends e-mail through SES"
      memory      = 256
      timeout     = 20
      vpc         = false
    }
  }

  common_env = {
    DB_SECRET_ARN      = aws_secretsmanager_secret.db.arn
    DB_HOST            = local.db_host
    DB_PORT            = local.db_port
    COGNITO_ISSUER     = "${coalesce(var.cognito_issuer_base, "https://cognito-idp.${var.region}.amazonaws.com")}/${aws_cognito_user_pool.main.id}"
    COGNITO_CLIENT_ID  = aws_cognito_user_pool_client.web.id
    DB_NAME            = "exams"
    DB_SSL             = var.db_ssl
    UPLOAD_BUCKET      = aws_s3_bucket.uploads.bucket
    MARKING_QUEUE_URL  = local.q_marking.url
    EMAIL_QUEUE_URL    = local.q_email.url
    EVENT_BUS_NAME     = aws_cloudwatch_event_bus.exam.name
    SES_SENDER         = var.ses_sender
    PUBLIC_S3_ENDPOINT = var.public_s3_endpoint == null ? "" : var.public_s3_endpoint
  }
}

data "archive_file" "fn" {
  for_each    = local.functions
  type        = "zip"
  source_dir  = "${path.module}/${var.build_dir}/${each.key}"
  output_path = "${path.module}/../build/zips/${each.key}.zip"
}

# ---------------------------------------------------------------- IAM: one role per function

resource "aws_iam_role" "fn" {
  for_each = local.functions
  name     = "${local.name}-${replace(each.key, "_", "-")}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

locals {
  base_statements = [
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/${local.name}-*:*" },
    { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = "*" },
  ]
  vpc_statements = [
    { Effect = "Allow", Action = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"], Resource = "*" },
  ]
  db_statements = [
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.db.arn },
    { Effect = "Allow", Action = ["kms:Decrypt"], Resource = aws_kms_key.data.arn },
  ]
  fn_statements = {
    exam_api = [
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = local.q_marking.arn },
      { Effect = "Allow", Action = ["events:PutEvents"], Resource = aws_cloudwatch_event_bus.exam.arn },
      # The presigned POST/GET is signed with these credentials, so they bound what a URL can do.
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject"], Resource = "${aws_s3_bucket.uploads.arn}/submissions/*" },
      { Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = aws_kms_key.data.arn },
    ]
    submission_processor = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = local.q_uploads.arn },
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.uploads.arn}/submissions/*" },
      { Effect = "Allow", Action = ["events:PutEvents"], Resource = aws_cloudwatch_event_bus.exam.arn },
    ]
    auto_marker = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = local.q_marking.arn },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = local.q_email.arn },
    ]
    notifier = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = local.q_email.arn },
      { Effect = "Allow", Action = ["ses:SendEmail"], Resource = "*", Condition = { StringEquals = { "ses:FromAddress" = var.ses_sender } } },
    ]
  }
}

resource "aws_iam_role_policy" "fn" {
  for_each = local.functions
  name     = "least-privilege"
  role     = aws_iam_role.fn[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      local.base_statements,
      each.value.vpc ? concat(local.vpc_statements, local.db_statements) : [],
      local.fn_statements[each.key],
    )
  })
}

# ---------------------------------------------------------------- functions

resource "aws_cloudwatch_log_group" "fn" {
  for_each          = local.functions
  name              = "/aws/lambda/${local.name}-${replace(each.key, "_", "-")}"
  retention_in_days = 90
}

resource "aws_lambda_function" "fn" {
  for_each         = local.functions
  function_name    = "${local.name}-${replace(each.key, "_", "-")}"
  description      = each.value.description
  role             = aws_iam_role.fn[each.key].arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.fn[each.key].output_path
  source_code_hash = data.archive_file.fn[each.key].output_base64sha256
  memory_size      = each.value.memory
  timeout          = each.value.timeout
  publish          = each.key == "exam_api"

  environment {
    variables = local.common_env
  }

  dynamic "vpc_config" {
    for_each = each.value.vpc ? [1] : []
    content {
      subnet_ids         = aws_subnet.app[*].id
      security_group_ids = [aws_security_group.lambda.id]
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy.fn]
}

# The API is invoked through an alias so warm (provisioned) environments can be kept
# for exam windows without touching $LATEST.
resource "aws_lambda_alias" "exam_api_live" {
  name             = "live"
  function_name    = aws_lambda_function.fn["exam_api"].function_name
  function_version = aws_lambda_function.fn["exam_api"].version
}

resource "aws_lambda_provisioned_concurrency_config" "exam_api" {
  count                             = var.exam_api_provisioned_concurrency > 0 ? 1 : 0
  function_name                     = aws_lambda_function.fn["exam_api"].function_name
  qualifier                         = aws_lambda_alias.exam_api_live.name
  provisioned_concurrent_executions = var.exam_api_provisioned_concurrency
}

# ---------------------------------------------------------------- queue triggers

locals {
  triggers = {
    submission_processor = { queue = local.q_uploads.arn, batch = 10, max_concurrency = 20 }
    auto_marker          = { queue = local.q_marking.arn, batch = 10, max_concurrency = 20 }
    notifier             = { queue = local.q_email.arn, batch = 10, max_concurrency = 5 } # stays under the SES send rate
  }
}

resource "aws_lambda_event_source_mapping" "sqs" {
  for_each                           = local.triggers
  event_source_arn                   = each.value.queue
  function_name                      = aws_lambda_function.fn[each.key].arn
  batch_size                         = each.value.batch
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"]
  scaling_config {
    maximum_concurrency = each.value.max_concurrency
  }
}
