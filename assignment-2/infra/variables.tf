variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "exam"
}

variable "region" {
  description = "Region for the platform. ap-south-1 (Mumbai) is the closest region to Bhutan; Floci runs us-east-1."
  type        = string
  default     = "ap-south-1"
}

variable "aws_endpoint" {
  description = "Set to the Floci endpoint (http://localhost:4566) to deploy locally; null deploys to real AWS."
  type        = string
  default     = null
}

variable "public_s3_endpoint" {
  description = "Host the browser uses for presigned S3 URLs. Floci only (Lambda reaches S3 as floci:4566, the browser as localhost:4566); null on AWS."
  type        = string
  default     = null
}

variable "cognito_issuer_base" {
  description = "Base of the Cognito token issuer URL. null means AWS (https://cognito-idp.<region>.amazonaws.com); Floci issues tokens as http://floci:4566/<pool-id>."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "db_instance_class" {
  description = "RDS instance class. db.r6g.large sizes the exam-week peak; Floci ignores it."
  type        = string
  default     = "db.r6g.large"
}

variable "db_ssl" {
  description = "require on AWS (rds.force_ssl=1). Floci's PostgreSQL container has no TLS, so floci.tfvars sets disable."
  type        = string
  default     = "require"
}

variable "db_backup_retention_days" {
  description = "Automated backups with point-in-time recovery (5-minute transaction-log RPO)."
  type        = number
  default     = 35
}

variable "enable_rds_proxy" {
  description = "RDS Proxy pools Lambda connections and shortens Multi-AZ failover. Floci has no RDS Proxy."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "Private VPC interface endpoints for Secrets Manager, SQS, EventBridge and KMS."
  type        = bool
  default     = true
}

variable "exam_api_provisioned_concurrency" {
  description = "Warm execution environments kept for the exam API during exam windows (0 disables)."
  type        = number
  default     = 100
}

variable "domain_name" {
  description = "Public hostname, for example exams.cst.edu.bt. null skips Route 53, ACM and the custom CloudFront alias."
  type        = string
  default     = null
}

variable "ses_sender" {
  description = "Verified SES sender address for notifications."
  type        = string
  default     = "no-reply@exams.example.edu"
}

variable "alarm_email" {
  description = "Operations e-mail subscribed to CloudWatch alarms (null for none)."
  type        = string
  default     = null
}

variable "create_demo_users" {
  description = "Create one student, one tutor and one administrator (staging and Floci only)."
  type        = bool
  default     = false
}

variable "demo_password" {
  description = "Password for the demo users. Only used when create_demo_users is true."
  type        = string
  default     = null
  sensitive   = true
}

variable "build_dir" {
  description = "Where scripts/build.sh put the packaged functions."
  type        = string
  default     = "../build/functions"
}
