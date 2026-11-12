# VPC across two Availability Zones, three tiers of subnets (/19 each, 8,187 usable
# addresses: room for Lambda's network interfaces at exam-week concurrency):
#   public  (NAT gateways)                      10.20.0.0/19,   10.20.32.0/19
#   app     (Lambda ENIs, RDS Proxy, endpoints)  10.20.64.0/19,  10.20.96.0/19
#   data    (RDS primary and standby)            10.20.128.0/19, 10.20.160.0/19
# One NAT gateway per AZ, so losing an AZ never removes the other AZ's way out.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 3, count.index)
  tags              = { Name = "${local.name}-public-${substr(local.azs[count.index], -1, 1)}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 3, 2 + count.index)
  tags              = { Name = "${local.name}-app-${substr(local.azs[count.index], -1, 1)}", Tier = "app" }
}

resource "aws_subnet" "data" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 3, 4 + count.index)
  tags              = { Name = "${local.name}-data-${substr(local.azs[count.index], -1, 1)}", Tier = "data" }
}

resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip-${substr(local.azs[count.index], -1, 1)}" }
}

resource "aws_nat_gateway" "main" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.name}-nat-${substr(local.azs[count.index], -1, 1)}" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ, each pointing at its own AZ's NAT gateway.
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = { Name = "${local.name}-private-rt-${substr(local.azs[count.index], -1, 1)}" }
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "data" {
  count          = 2
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# S3 traffic from the private subnets stays on the AWS network (and costs no NAT data).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = { Name = "${local.name}-s3-endpoint" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = var.enable_interface_endpoints ? toset(["secretsmanager", "sqs", "events", "kms"]) : toset([])
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-${each.key}-endpoint" }
}

# ---------------------------------------------------------------- security groups

resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda-sg"
  description = "Lambda functions in the app subnets"
  vpc_id      = aws_vpc.main.id
  egress {
    description = "HTTPS to AWS APIs and PostgreSQL to the proxy/database"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-lambda-sg" }
}

resource "aws_security_group" "proxy" {
  name        = "${local.name}-rds-proxy-sg"
  description = "RDS Proxy: PostgreSQL from the Lambda functions only"
  vpc_id      = aws_vpc.main.id
  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
  egress {
    description = "PostgreSQL to the database"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  tags = { Name = "${local.name}-rds-proxy-sg" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "RDS: PostgreSQL from RDS Proxy (and Lambda when no proxy)"
  vpc_id      = aws_vpc.main.id
  ingress {
    description     = "PostgreSQL from the proxy tier"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.enable_rds_proxy ? [aws_security_group.proxy.id] : [aws_security_group.lambda.id]
  }
  tags = { Name = "${local.name}-db-sg" }
}

resource "aws_security_group" "endpoints" {
  name        = "${local.name}-endpoints-sg"
  description = "Interface endpoints: HTTPS from the Lambda functions"
  vpc_id      = aws_vpc.main.id
  ingress {
    description     = "HTTPS from Lambda"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
  tags = { Name = "${local.name}-endpoints-sg" }
}
