# Edge: Route 53 -> CloudFront (+ AWS WAF) -> { S3 frontend | API Gateway }.

# ---------------------------------------------------------------- WAF (scope CLOUDFRONT, us-east-1)

resource "aws_wafv2_web_acl" "edge" {
  provider    = aws.us_east_1
  name        = "${local.name}-edge-acl"
  description = "Managed protections plus a per-IP rate limit sized for campus NAT"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesCommonRuleSet          = 10
      AWSManagedRulesKnownBadInputsRuleSet  = 20
      AWSManagedRulesAmazonIpReputationList = 30
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  # Thousands of students in a lab can share one campus NAT address, so the per-IP
  # limit is generous (an exam hall of 3,000 autosaving twice a minute is ~30,000
  # requests per 5 minutes) and only stops floods, not a busy exam hall.
  rule {
    name     = "per-ip-rate-limit"
    priority = 40
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 50000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "per-ip-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-edge-acl"
    sampled_requests_enabled   = true
  }
}

# ---------------------------------------------------------------- certificate and DNS

resource "aws_route53_zone" "main" {
  count = var.domain_name == null ? 0 : 1
  name  = var.domain_name
}

resource "aws_acm_certificate" "edge" {
  count             = var.domain_name == null ? 0 : 1
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.domain_name == null ? {} : {
    for o in aws_acm_certificate.edge[0].domain_validation_options : o.domain_name => o
  }
  zone_id = aws_route53_zone.main[0].zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

# Real AWS waits here until the certificate is issued; Floci has no DNS validation.
resource "aws_acm_certificate_validation" "edge" {
  count                   = var.domain_name != null && !local.floci ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.edge[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------------------------------------------------------------- CloudFront

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  api_origin_domain = "${aws_api_gateway_rest_api.exam.id}.execute-api.${var.region}.amazonaws.com"
}

# AWS only: reading back a Floci 1.5.34 distribution crashes provider 6.57.1 (nil pointer in
# resourceDistributionFlatten - Floci drops fields such as ForwardedValues). On Floci the
# app is served straight from the S3 bucket instead.
resource "aws_cloudfront_distribution" "main" {
  count               = local.floci ? 0 : 1
  enabled             = true
  comment             = "${local.name} frontend and API"
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # includes edge locations in India, closest to Bhutan
  web_acl_id          = aws_wafv2_web_acl.edge.arn
  aliases             = var.domain_name != null && !local.floci ? [var.domain_name] : []

  origin {
    origin_id                = "frontend-s3"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    origin_id   = "exam-api"
    domain_name = local.api_origin_domain
    origin_path = "/${aws_api_gateway_stage.prod.stage_name}"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # The app: cached at the edge, so 3,000 students opening the exam page at once
  # are served by CloudFront, not by the origin.
  default_cache_behavior {
    target_origin_id       = "frontend-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  }

  # The API: never cached, every method, the Authorization header passed through.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "exam-api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # Managed-AllViewerExceptHostHeader
  }

  # SPA routing: unknown paths return the app shell.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.domain_name == null || local.floci
    acm_certificate_arn            = var.domain_name != null && !local.floci ? aws_acm_certificate_validation.edge[0].certificate_arn : null
    ssl_support_method             = var.domain_name != null && !local.floci ? "sni-only" : null
    minimum_protocol_version       = var.domain_name != null && !local.floci ? "TLSv1.2_2021" : null
  }

  logging_config {
    bucket = aws_s3_bucket.logs.bucket_domain_name
    prefix = "cloudfront/"
  }
}

# CloudFront (and only this distribution) may read the frontend bucket.
resource "aws_s3_bucket_policy" "frontend" {
  count  = local.floci ? 0 : 1
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontReadOnly"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.main[0].arn } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.all]
}

resource "aws_route53_record" "app" {
  count   = var.domain_name == null || local.floci ? 0 : 1
  zone_id = aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}
