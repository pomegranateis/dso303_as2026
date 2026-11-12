# Local deployment on Floci (the course's AWS emulator).
# Everything else keeps the production defaults in variables.tf.
region              = "us-east-1"
aws_endpoint        = "http://localhost:4566"
public_s3_endpoint  = "http://localhost:4566"
cognito_issuer_base = "http://floci:4566" # how Floci names its token issuer (FLOCI_HOSTNAME)

db_instance_class = "db.t4g.micro"
db_ssl            = "disable" # Floci's postgres:16-alpine container has no TLS listener

# Not emulated by Floci 1.5.34 (see README "Floci differences"):
enable_rds_proxy                 = false
exam_api_provisioned_concurrency = 0

domain_name       = "exams.dso303.test"
create_demo_users = true
demo_password     = "ExamDemo#2026"
