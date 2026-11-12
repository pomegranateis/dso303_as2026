# API Gateway (REST, regional). Everything lives under /api so CloudFront can send
# /api/* to this API and everything else to the S3 frontend, on one domain.
#   GET     /api/health        no auth (health checks)
#   ANY     /api/{proxy+}      Cognito user-pool authorizer (valid ID token required)
#   OPTIONS /api/{proxy+}      no auth (CORS preflight)

resource "aws_api_gateway_rest_api" "exam" {
  name        = "${local.name}-api"
  description = "Online exam platform API"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "api" {
  rest_api_id = aws_api_gateway_rest_api.exam.id
  parent_id   = aws_api_gateway_rest_api.exam.root_resource_id
  path_part   = "api"
}

resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.exam.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "health"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.exam.id
  parent_id   = aws_api_gateway_resource.api.id
  path_part   = "{proxy+}"
}

# AWS only. Floci 1.5.34 neither stores the pool ARNs (so every plan would try an
# UpdateAuthorizer Floci lacks) nor enforces the check; there the function verifies the
# token itself (app/functions/common/auth.py), which it also does on AWS as a second layer.
resource "aws_api_gateway_authorizer" "cognito" {
  count           = local.floci ? 0 : 1
  name            = "${local.name}-cognito"
  rest_api_id     = aws_api_gateway_rest_api.exam.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [aws_cognito_user_pool.main.arn]
  identity_source = "method.request.header.Authorization"
}
locals {
  api_methods = {
    health        = { resource = aws_api_gateway_resource.health.id, method = "GET", auth = "NONE" }
    proxy_any     = { resource = aws_api_gateway_resource.proxy.id, method = "ANY", auth = local.floci ? "NONE" : "COGNITO_USER_POOLS" }
    proxy_options = { resource = aws_api_gateway_resource.proxy.id, method = "OPTIONS", auth = "NONE" }
  }
}

resource "aws_api_gateway_method" "m" {
  for_each      = local.api_methods
  rest_api_id   = aws_api_gateway_rest_api.exam.id
  resource_id   = each.value.resource
  http_method   = each.value.method
  authorization = each.value.auth
  authorizer_id = each.value.auth == "COGNITO_USER_POOLS" ? aws_api_gateway_authorizer.cognito[0].id : null
}

resource "aws_api_gateway_integration" "m" {
  for_each                = local.api_methods
  rest_api_id             = aws_api_gateway_rest_api.exam.id
  resource_id             = each.value.resource
  http_method             = aws_api_gateway_method.m[each.key].http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  # Floci 1.5.34 reads an alias-qualified ARN as a function called "live"; on AWS the
  # alias is what carries the provisioned (warm) concurrency.
  uri = local.floci ? aws_lambda_function.fn["exam_api"].invoke_arn : aws_lambda_alias.exam_api_live.invoke_arn
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["exam_api"].function_name
  qualifier     = local.floci ? null : aws_lambda_alias.exam_api_live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.exam.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "exam" {
  rest_api_id = aws_api_gateway_rest_api.exam.id
  triggers = {
    redeploy = sha1(jsonencode([local.api_methods, [for i in aws_api_gateway_integration.m : [i.id, i.uri]], aws_api_gateway_authorizer.cognito[*].id]))
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [aws_api_gateway_integration.m]
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name}-api-access"
  retention_in_days = 90
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id          = aws_api_gateway_rest_api.exam.id
  deployment_id        = aws_api_gateway_deployment.exam.id
  stage_name           = "prod"
  xray_tracing_enabled = true
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId = "$context.requestId", ip = "$context.identity.sourceIp", user = "$context.authorizer.claims.sub",
      method    = "$context.httpMethod", path = "$context.path", status = "$context.status",
      latencyMs = "$context.responseLatency", integrationMs = "$context.integrationLatency"
    })
  }
  depends_on = [aws_api_gateway_account.main]
}

# Exam week: 3,000 students start within 5 minutes, then ~100 autosaves/second.
# The stage limits sit well above that and well below what the database tier is sized for.
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.exam.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"
  settings {
    metrics_enabled        = true
    logging_level          = "ERROR"
    throttling_rate_limit  = 1000
    throttling_burst_limit = 2000
  }
}

# Account-level role API Gateway uses to write logs to CloudWatch.
resource "aws_iam_role" "apigw_logs" {
  name = "${local.name}-apigw-cloudwatch-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "apigateway.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "apigw_logs" {
  name = "write-logs"
  role = aws_iam_role.apigw_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:PutLogEvents", "logs:GetLogEvents", "logs:FilterLogEvents"]
      Resource = "*"
    }]
  })
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.apigw_logs.arn
}

locals {
  # On AWS the browser calls /api/... on the CloudFront domain. On Floci it calls
  # API Gateway's local invoke path directly.
  api_invoke_base = local.floci ? "${var.aws_endpoint}/restapis/${aws_api_gateway_rest_api.exam.id}/${aws_api_gateway_stage.prod.stage_name}/_user_request_" : ""
}
