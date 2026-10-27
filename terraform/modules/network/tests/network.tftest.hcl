# Runs without AWS credentials: the provider is mocked, so plans and applies only
# exercise this module's logic. `command = apply` is used where an assertion needs
# values AWS would compute (IDs, ARNs), which the mock fills in.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-central-1"
    }
  }

  # The real provider still validates arguments, so computed ARNs must look real.
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-central-1:123456789012:log-group:/vpc/obs-test/flow-logs"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/obs-test-flow-logs-20261027"
    }
  }
}

variables {
  name = "obs-test"
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.20.0.0/16" && aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "The VPC must use 10.20.0.0/16 with DNS support and hostnames."
  }

  assert {
    condition     = aws_subnet.public.cidr_block == "10.20.0.0/24"
    error_message = "The subnet must default to the first /24 of the VPC."
  }

  assert {
    condition     = aws_subnet.public.availability_zone == "eu-central-1a"
    error_message = "The subnet must default to the first available zone."
  }

  assert {
    condition     = aws_subnet.public.map_public_ip_on_launch == false
    error_message = "Instances must not get automatic public IPs (they use Elastic IPs)."
  }

  assert {
    condition     = aws_route.internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "The public route table needs a default route."
  }

  assert {
    condition     = aws_vpc.this.tags.Name == "obs-test" && aws_subnet.public.tags.Name == "obs-test-public"
    error_message = "Resources must carry Name tags derived from var.name."
  }
}

run "wiring_and_flow_logs" {
  command = apply

  assert {
    condition     = aws_default_security_group.this.vpc_id == aws_vpc.this.id
    error_message = "The VPC's default security group must be adopted (which strips its rules)."
  }

  assert {
    condition = (
      aws_route.internet.gateway_id == aws_internet_gateway.this.id &&
      aws_route_table_association.public.subnet_id == aws_subnet.public.id &&
      aws_route_table_association.public.route_table_id == aws_route_table.public.id
    )
    error_message = "The subnet must route to the internet gateway."
  }

  assert {
    condition     = aws_flow_log.this[0].traffic_type == "REJECT" && aws_flow_log.this[0].log_destination_type == "cloud-watch-logs"
    error_message = "Rejected traffic must be logged to CloudWatch Logs by default."
  }

  assert {
    condition     = aws_flow_log.this[0].log_destination == aws_cloudwatch_log_group.flow_logs[0].arn && aws_flow_log.this[0].iam_role_arn == aws_iam_role.flow_logs[0].arn
    error_message = "The flow log must write to its own log group through its own role."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].name == "/vpc/obs-test/flow-logs" && aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 90
    error_message = "The flow log group must be named after the VPC and keep records for 90 days."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.flow_logs[0].policy).Statement[0].Resource == "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
    error_message = "The flow log role may only write to its own log group."
  }

  assert {
    condition = jsondecode(aws_iam_role.flow_logs[0].assume_role_policy).Statement[0].Condition == {
      StringEquals = { "aws:SourceAccount" = "123456789012" }
      ArnLike      = { "aws:SourceArn" = "arn:aws:ec2:eu-central-1:123456789012:vpc-flow-log/*" }
    }
    error_message = "Only flow logs of this account and region may assume the role."
  }

  assert {
    condition     = output.subnet_id == aws_subnet.public.id && output.vpc_id == aws_vpc.this.id && output.flow_log_group_name == "/vpc/obs-test/flow-logs"
    error_message = "Outputs must expose the created resources."
  }
}

run "flow_logs_disabled" {
  command = plan

  variables {
    flow_logs_enabled = false
  }

  assert {
    condition = (
      length(aws_flow_log.this) == 0 &&
      length(aws_cloudwatch_log_group.flow_logs) == 0 &&
      length(aws_iam_role.flow_logs) == 0 &&
      length(aws_iam_role_policy.flow_logs) == 0
    )
    error_message = "Disabling flow logs must remove the log group, the role and the flow log."
  }

  assert {
    condition     = output.flow_log_group_name == null
    error_message = "flow_log_group_name must be null without flow logs."
  }
}

run "explicit_zone_and_subnet" {
  command = plan

  variables {
    vpc_cidr          = "10.30.0.0/20"
    subnet_cidr       = "10.30.4.0/24"
    availability_zone = "eu-central-1b"
  }

  assert {
    condition     = aws_subnet.public.cidr_block == "10.30.4.0/24" && aws_subnet.public.availability_zone == "eu-central-1b"
    error_message = "Explicit subnet CIDR and zone must be used as given."
  }

  assert {
    condition     = length(data.aws_availability_zones.available) == 0
    error_message = "Zones must not be looked up when one is given."
  }
}

run "small_vpc_uses_whole_range" {
  command = plan

  variables {
    vpc_cidr = "10.40.7.0/24"
  }

  assert {
    condition     = aws_subnet.public.cidr_block == "10.40.7.0/24"
    error_message = "A /24 VPC must get a subnet spanning all of it."
  }
}

run "rejects_subnet_outside_vpc" {
  command = plan

  variables {
    subnet_cidr = "10.99.0.0/24"
  }

  expect_failures = [aws_subnet.public]
}

run "rejects_subnet_larger_than_vpc" {
  command = plan

  variables {
    vpc_cidr    = "10.20.0.0/20"
    subnet_cidr = "10.20.0.0/16"
  }

  expect_failures = [aws_subnet.public]
}

run "rejects_host_bits_in_vpc_cidr" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.1/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_vpc_larger_than_aws_allows" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/8"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_ipv6_vpc_cidr" {
  command = plan

  variables {
    vpc_cidr = "2001:db8::/56"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_unknown_traffic_type" {
  command = plan

  variables {
    flow_logs_traffic_type = "DROPPED"
  }

  expect_failures = [var.flow_logs_traffic_type]
}

run "rejects_unsupported_retention" {
  command = plan

  variables {
    flow_logs_retention_days = 45
  }

  expect_failures = [var.flow_logs_retention_days]
}

run "rejects_invalid_name" {
  command = plan

  variables {
    name = "Observability_Lab"
  }

  expect_failures = [var.name]
}
