# The single-page app is part of the deployment: every file in app/frontend is
# uploaded, and config.js is generated from the resources it talks to, so one
# `terraform apply` produces a working site with no manual steps.

locals {
  frontend_dir = "${path.module}/../app/frontend"
  mime = {
    html = "text/html; charset=utf-8"
    js   = "application/javascript"
    css  = "text/css"
    svg  = "image/svg+xml"
    png  = "image/png"
    ico  = "image/x-icon"
  }
}

resource "aws_s3_object" "frontend" {
  for_each      = fileset(local.frontend_dir, "**")
  bucket        = aws_s3_bucket.frontend.id
  key           = each.value
  source        = "${local.frontend_dir}/${each.value}"
  etag          = filemd5("${local.frontend_dir}/${each.value}")
  content_type  = lookup(local.mime, reverse(split(".", each.value))[0], "application/octet-stream")
  cache_control = endswith(each.value, ".html") ? "no-cache" : "public, max-age=300"
}

resource "aws_s3_object" "frontend_config" {
  bucket        = aws_s3_bucket.frontend.id
  key           = "config.js"
  content_type  = "application/javascript"
  cache_control = "no-cache"
  content = "window.EXAM_CONFIG = ${jsonencode({
    apiBase         = local.api_invoke_base
    cognitoEndpoint = local.floci ? var.aws_endpoint : "https://cognito-idp.${var.region}.amazonaws.com"
    userPoolId      = aws_cognito_user_pool.main.id
    clientId        = aws_cognito_user_pool_client.web.id
    autosaveSeconds = 30
    maxUploadBytes  = 52428800
    environment     = local.floci ? "floci" : "aws"
  })};\n"
}
