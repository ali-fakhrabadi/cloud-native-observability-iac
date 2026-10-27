# A VPC with one public subnet for a single monitoring host: no NAT gateway, because
# the host has an Elastic IP and its security group is the perimeter.

data "aws_availability_zones" "available" {
  count = var.availability_zone == null ? 1 : 0
  state = "available"

  # Local Zones and Wavelength Zones lack services and instance types.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  vpc_prefix        = tonumber(split("/", var.vpc_cidr)[1])
  subnet_cidr       = var.subnet_cidr != null ? var.subnet_cidr : cidrsubnet(var.vpc_cidr, max(24 - local.vpc_prefix, 0), 0)
  subnet_prefix     = tonumber(split("/", local.subnet_cidr)[1])
  availability_zone = var.availability_zone != null ? var.availability_zone : data.aws_availability_zones.available[0].names[0]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# Adopting the default security group removes the rules AWS creates in it, so nothing
# that falls back to it gets open access (CIS AWS Foundations 5.4).
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-deny-all" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnet_cidr
  availability_zone = local.availability_zone
  # Hosts get an Elastic IP instead, which survives instance replacement.
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.name}-public" })

  lifecycle {
    precondition {
      condition = (
        local.subnet_prefix >= local.vpc_prefix &&
        cidrsubnet("${cidrhost(local.subnet_cidr, 0)}/${local.vpc_prefix}", 0, 0) == var.vpc_cidr
      )
      error_message = "subnet_cidr ${local.subnet_cidr} is not inside vpc_cidr ${var.vpc_cidr}."
    }
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Flow logs ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.flow_logs_enabled ? 1 : 0

  name              = "/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.flow_logs_enabled ? 1 : 0

  name_prefix = "${substr(var.name, 0, 27)}-flow-logs-"
  # Only the flow logs of this account and region may assume the role (confused deputy).
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.flow_logs_enabled ? 1 : 0

  name = "write-flow-logs"
  role = aws_iam_role.flow_logs[0].id
  # Scoped to this log group's streams, which the service creates with generated names.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count = var.flow_logs_enabled ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = var.flow_logs_traffic_type
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(var.tags, { Name = var.name })
}
