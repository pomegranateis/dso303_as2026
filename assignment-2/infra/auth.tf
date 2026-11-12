# Amazon Cognito: sign-in for 8,400 users, roles as groups.
# Accounts are provisioned by the university (no self sign-up); the group a user
# belongs to appears as the cognito:groups claim in the ID token, which the API's
# Cognito authorizer validates and the functions use for role checks.

resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  # TOTP MFA (required for staff by policy). Floci 1.5.34 has no SetUserPoolMfaConfig.
  mfa_configuration = local.floci ? "OFF" : "OPTIONAL"

  dynamic "software_token_mfa_configuration" {
    for_each = local.floci ? [] : [1]
    content {
      enabled = true
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  user_pool_add_ons {
    advanced_security_mode = local.floci ? "OFF" : "ENFORCED" # compromised-credential and risk checks
  }

  deletion_protection = local.floci ? "INACTIVE" : "ACTIVE"
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  # SRP keeps the password off the wire on AWS; USER_PASSWORD_AUTH is what the
  # plain-JavaScript demo client uses against Floci.
  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]

  generate_secret               = false
  prevent_user_existence_errors = "ENABLED"
  id_token_validity             = 4 # hours: longer than the longest exam
  access_token_validity         = 4
  refresh_token_validity        = 12 # hours
  token_validity_units {
    id_token      = "hours"
    access_token  = "hours"
    refresh_token = "hours"
  }
}

resource "aws_cognito_user_group" "role" {
  for_each     = toset(["students", "tutors", "admins"])
  name         = each.key
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Platform role: ${each.key}"
}

# ---------------------------------------------------------------- demo users (Floci / staging only)

locals {
  demo_users = var.create_demo_users ? {
    student1 = { email = "student1@exams.example.edu", group = "students" }
    tutor1   = { email = "tutor1@exams.example.edu", group = "tutors" }
    admin1   = { email = "admin1@exams.example.edu", group = "admins" }
  } : {}
}

resource "aws_cognito_user" "demo" {
  for_each     = local.demo_users
  user_pool_id = aws_cognito_user_pool.main.id
  username     = each.value.email
  password     = var.demo_password
  attributes = {
    email          = each.value.email
    email_verified = "true"
  }
}

resource "aws_cognito_user_in_group" "demo" {
  for_each     = local.demo_users
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.role[each.value.group].name
  username     = aws_cognito_user.demo[each.key].username
}
