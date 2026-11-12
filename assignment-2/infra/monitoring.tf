# Monitoring: alarms to the ops SNS topic, one exam-day dashboard, and an audit trail.

locals {
  alarms = {
    api-5xx = {
      namespace = "AWS/ApiGateway", metric = "5XXError", stat = "Sum", threshold = 5, period = 60
      dims      = { ApiName = aws_api_gateway_rest_api.exam.name, Stage = "prod" }
      desc      = "API returning server errors during an exam"
    }
    api-latency-p95 = {
      namespace = "AWS/ApiGateway", metric = "Latency", stat = "p95", threshold = 1000, period = 60
      dims      = { ApiName = aws_api_gateway_rest_api.exam.name, Stage = "prod" }
      desc      = "Autosave/start latency above 1 s at p95"
    }
    exam-api-errors = {
      namespace = "AWS/Lambda", metric = "Errors", stat = "Sum", threshold = 5, period = 60
      dims      = { FunctionName = aws_lambda_function.fn["exam_api"].function_name }
      desc      = "Exam API function errors"
    }
    exam-api-throttles = {
      namespace = "AWS/Lambda", metric = "Throttles", stat = "Sum", threshold = 1, period = 60
      dims      = { FunctionName = aws_lambda_function.fn["exam_api"].function_name }
      desc      = "Exam API hitting its concurrency limit"
    }
    db-cpu = {
      namespace = "AWS/RDS", metric = "CPUUtilization", stat = "Average", threshold = 80, period = 300
      dims      = { DBInstanceIdentifier = aws_db_instance.main.identifier }
      desc      = "Database CPU above 80%"
    }
    db-connections = {
      namespace = "AWS/RDS", metric = "DatabaseConnections", stat = "Maximum", threshold = 800, period = 60
      dims      = { DBInstanceIdentifier = aws_db_instance.main.identifier }
      desc      = "Database connections close to the instance limit"
    }
    db-free-storage = {
      namespace = "AWS/RDS", metric = "FreeStorageSpace", stat = "Minimum", threshold = 10737418240, period = 300, lower = true
      dims      = { DBInstanceIdentifier = aws_db_instance.main.identifier }
      desc      = "Less than 10 GB of database storage left"
    }
    email-backlog-age = {
      namespace = "AWS/SQS", metric = "ApproximateAgeOfOldestMessage", stat = "Maximum", threshold = 900, period = 60
      dims      = { QueueName = local.q_email.name }
      desc      = "E-mails waiting more than 15 minutes"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "main" {
  for_each            = local.alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.desc
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = contains(["Sum", "Average", "Maximum", "Minimum"], each.value.stat) ? each.value.stat : null
  extended_statistic  = contains(["Sum", "Average", "Maximum", "Minimum"], each.value.stat) ? null : each.value.stat
  dimensions          = each.value.dims
  period              = each.value.period
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = each.value.threshold
  comparison_operator = try(each.value.lower, false) ? "LessThanThreshold" : "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
}

# Any message in a dead-letter queue means a submission, a mark or an e-mail needs a person.
resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each            = aws_sqs_queue.dlq
  alarm_name          = "${local.name}-${each.key}-dlq-not-empty"
  alarm_description   = "Messages in the ${each.key} dead-letter queue"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  dimensions          = { QueueName = each.value.name }
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
}

# AWS only: Floci 1.5.34 has no CloudWatch PutDashboard.
resource "aws_cloudwatch_dashboard" "exam_day" {
  count          = local.floci ? 0 : 1
  dashboard_name = "${local.name}-exam-day"
  dashboard_body = jsonencode({
    widgets = [
      { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
        title = "API requests and errors", region = var.region, stat = "Sum", period = 60,
        metrics = [["AWS/ApiGateway", "Count", "ApiName", aws_api_gateway_rest_api.exam.name, "Stage", "prod"],
      [".", "4XXError", ".", ".", ".", "."], [".", "5XXError", ".", ".", ".", "."]] } },
      { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
        title = "API latency (p50, p95)", region = var.region, period = 60,
        metrics = [["AWS/ApiGateway", "Latency", "ApiName", aws_api_gateway_rest_api.exam.name, "Stage", "prod", { stat = "p50" }],
      ["...", { stat = "p95" }]] } },
      { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = {
        title = "Exam API concurrency and throttles", region = var.region, stat = "Maximum", period = 60,
        metrics = [["AWS/Lambda", "ConcurrentExecutions", "FunctionName", aws_lambda_function.fn["exam_api"].function_name],
      [".", "Throttles", ".", ".", { stat = "Sum" }]] } },
      { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = {
        title = "Database", region = var.region, stat = "Average", period = 60,
        metrics = [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier],
      [".", "DatabaseConnections", ".", "."]] } },
      { type = "metric", x = 0, y = 12, width = 24, height = 6, properties = {
        title = "Queue backlog", region = var.region, stat = "Maximum", period = 60,
      metrics = [for k, q in aws_sqs_queue.work : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q.name]] } },
    ]
  })
}

# ---------------------------------------------------------------- audit trail

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.logs.arn
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.all]
}

# Floci 1.5.34 has no CloudTrail ListTags, which the provider calls on every read.
resource "aws_cloudtrail" "audit" {
  count                         = local.floci ? 0 : 1
  name                          = "${local.name}-audit"
  s3_bucket_name                = aws_s3_bucket.logs.id
  s3_key_prefix                 = "cloudtrail"
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  # Who read or wrote which assignment file, for academic-integrity investigations.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.uploads.arn}/submissions/"]
    }
  }
  depends_on = [aws_s3_bucket_policy.logs]
}
