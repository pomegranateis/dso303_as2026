terraform {
  required_version = ">= 1.6"
  required_providers {
    # 6.57.1 exactly: 6.58.0 added a wait for a REST API "status" field that Floci 1.5.34
    # does not return, so API creation never completes there.
    aws     = { source = "hashicorp/aws", version = "6.57.1" }
    archive = { source = "hashicorp/archive", version = "~> 2.7" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

locals {
  # One code base, two targets. With aws_endpoint set (floci.tfvars) every service
  # call goes to Floci; with it null (production) the provider uses real AWS.
  floci = var.aws_endpoint != null
  name  = var.project
  tags = {
    Project    = "online-exam-platform"
    Course     = "DSO303"
    Assignment = "2"
    ManagedBy  = "terraform"
  }
}

provider "aws" {
  region                      = var.region
  access_key                  = local.floci ? "test" : null
  secret_key                  = local.floci ? "test" : null
  skip_credentials_validation = local.floci
  skip_metadata_api_check     = local.floci
  skip_requesting_account_id  = local.floci
  s3_use_path_style           = local.floci

  endpoints {
    acm            = var.aws_endpoint
    apigateway     = var.aws_endpoint
    backup         = var.aws_endpoint
    cloudfront     = var.aws_endpoint
    cloudtrail     = var.aws_endpoint
    cloudwatch     = var.aws_endpoint
    cognitoidp     = var.aws_endpoint
    ec2            = var.aws_endpoint
    events         = var.aws_endpoint
    iam            = var.aws_endpoint
    kms            = var.aws_endpoint
    lambda         = var.aws_endpoint
    logs           = var.aws_endpoint
    rds            = var.aws_endpoint
    route53        = var.aws_endpoint
    s3             = var.aws_endpoint
    secretsmanager = var.aws_endpoint
    ses            = var.aws_endpoint
    sns            = var.aws_endpoint
    sqs            = var.aws_endpoint
    sts            = var.aws_endpoint
    wafv2          = var.aws_endpoint
  }

  default_tags { tags = local.tags }
}

# CloudFront's WAF web ACL and ACM certificate must be created in us-east-1,
# whatever region the platform runs in.
provider "aws" {
  alias                       = "us_east_1"
  region                      = "us-east-1"
  access_key                  = local.floci ? "test" : null
  secret_key                  = local.floci ? "test" : null
  skip_credentials_validation = local.floci
  skip_metadata_api_check     = local.floci
  skip_requesting_account_id  = local.floci

  endpoints {
    acm   = var.aws_endpoint
    wafv2 = var.aws_endpoint
    sts   = var.aws_endpoint
  }

  default_tags { tags = local.tags }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
