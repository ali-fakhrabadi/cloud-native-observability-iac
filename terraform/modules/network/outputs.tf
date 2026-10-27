output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "subnet_id" {
  description = "ID of the public subnet, available once it routes to the internet."
  value       = aws_subnet.public.id
  # Elastic IP associations fail until the VPC has an internet gateway and a route to it.
  depends_on = [aws_route.internet, aws_route_table_association.public]
}

output "subnet_cidr" {
  description = "IPv4 CIDR block of the public subnet."
  value       = aws_subnet.public.cidr_block
}

output "availability_zone" {
  description = "Availability Zone of the public subnet (known at plan time)."
  value       = local.availability_zone
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group holding the VPC flow logs, or null when they are disabled."
  value       = one(aws_cloudwatch_log_group.flow_logs[*].name)
}
