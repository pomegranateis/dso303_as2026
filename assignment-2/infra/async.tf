# Asynchronous processing: three work queues, each with a dead-letter queue, joined
# by a custom EventBridge bus.
#
#   S3 ObjectCreated ------------------------------> uploads queue -> submission_processor
#   API submit ------------------------------------> marking queue -> auto_marker
#   EventBridge ResultsReleased (rule) ------------> marking queue    (fans out result emails)
#   EventBridge SubmissionReceived (rule) ---------> email queue   -> notifier -> SES
#   auto_marker result jobs ------------------------> email queue

locals {
  queues = {
    uploads = { visibility = 120, consumer_timeout = 20 }
    marking = { visibility = 360, consumer_timeout = 60 }
    email   = { visibility = 120, consumer_timeout = 20 }
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each                  = local.queues
  name                      = "${local.name}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days to inspect and redrive
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "work" {
  for_each                   = local.queues
  name                       = "${local.name}-${each.key}-queue"
  visibility_timeout_seconds = each.value.visibility # at least 6x the consumer's timeout
  message_retention_seconds  = 345600                # 4 days
  receive_wait_time_seconds  = 20                    # long polling
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

# Friendlier names for the rest of the configuration.
locals {
  q_uploads = aws_sqs_queue.work["uploads"]
  q_marking = aws_sqs_queue.work["marking"]
  q_email   = aws_sqs_queue.work["email"]
}

resource "aws_sqs_queue_policy" "uploads" {
  queue_url = local.q_uploads.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "S3UploadsBucketOnly"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = local.q_uploads.arn
      Condition = {
        ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.uploads.arn }
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_sqs_queue_policy" "from_eventbridge" {
  for_each  = { marking = local.q_marking, email = local.q_email }
  queue_url = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ExamEventBusRulesOnly"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = each.value.arn
      Condition = { ArnLike = { "aws:SourceArn" = "${aws_cloudwatch_event_bus.exam.arn}/*" } }
    }]
  })
}

# ---------------------------------------------------------------- EventBridge

resource "aws_cloudwatch_event_bus" "exam" {
  name = "${local.name}-events"
}

resource "aws_cloudwatch_event_rule" "submission_received" {
  name           = "${local.name}-submission-received"
  description    = "Tell the tutor (and the student) when an upload is processed"
  event_bus_name = aws_cloudwatch_event_bus.exam.name
  event_pattern  = jsonencode({ source = ["exam-platform.uploads"], "detail-type" = ["SubmissionReceived"] })
}

resource "aws_cloudwatch_event_target" "submission_received" {
  rule           = aws_cloudwatch_event_rule.submission_received.name
  event_bus_name = aws_cloudwatch_event_bus.exam.name
  target_id      = "email-queue"
  arn            = local.q_email.arn
}

resource "aws_cloudwatch_event_rule" "results_released" {
  name           = "${local.name}-results-released"
  description    = "Fan out result e-mails when a tutor releases an exam"
  event_bus_name = aws_cloudwatch_event_bus.exam.name
  event_pattern  = jsonencode({ source = ["exam-platform.api"], "detail-type" = ["ResultsReleased"] })
}

resource "aws_cloudwatch_event_target" "results_released" {
  rule           = aws_cloudwatch_event_rule.results_released.name
  event_bus_name = aws_cloudwatch_event_bus.exam.name
  target_id      = "marking-queue"
  arn            = local.q_marking.arn
}

# Every platform event is kept 30 days so a failed consumer can be replayed.
resource "aws_cloudwatch_event_archive" "exam" {
  name             = "${local.name}-events-archive"
  event_source_arn = aws_cloudwatch_event_bus.exam.arn
  retention_days   = 30
}

# ---------------------------------------------------------------- email and alerts

resource "aws_ses_email_identity" "sender" {
  email = var.ses_sender
}

resource "aws_sns_topic" "ops_alerts" {
  name              = "${local.name}-ops-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "ops_email" {
  count     = var.alarm_email == null ? 0 : 1
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
