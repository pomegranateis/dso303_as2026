output "app_url" {
  description = "Open this in a browser."
  value = local.floci ? "${var.aws_endpoint}/${aws_s3_bucket.frontend.bucket}/index.html" : (
    var.domain_name != null ? "https://${var.domain_name}" : "https://${one(aws_cloudfront_distribution.main[*].domain_name)}"
  )
}

output "api_base_url" {
  value = local.floci ? "${local.api_invoke_base}/api" : "https://${one(aws_cloudfront_distribution.main[*].domain_name)}/api"
}

output "cloudfront_domain" {
  value = one(aws_cloudfront_distribution.main[*].domain_name)
}

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "upload_bucket" {
  value = aws_s3_bucket.uploads.bucket
}

output "frontend_bucket" {
  value = aws_s3_bucket.frontend.bucket
}

output "exam_api_function" {
  value = aws_lambda_function.fn["exam_api"].function_name
}

output "db_instance" {
  value = {
    identifier = aws_db_instance.main.identifier
    multi_az   = aws_db_instance.main.multi_az
    primary_az = aws_db_instance.main.availability_zone
    subnet_azs = local.azs
    endpoint   = local.db_host
  }
}

output "queues" {
  value = { for k, q in aws_sqs_queue.work : k => q.url }
}

output "event_bus" {
  value = aws_cloudwatch_event_bus.exam.name
}

output "demo_users" {
  description = "Demo accounts (Floci/staging only). The password is in floci.tfvars."
  value       = [for k, u in local.demo_users : "${u.email} (${u.group})"]
}
