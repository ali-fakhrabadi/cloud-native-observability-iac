output "instance_id" {
  description = "ID of the EC2 instance."
  value       = aws_instance.this.id
}

output "ami_id" {
  description = "AMI the instance runs."
  value       = aws_instance.this.ami
}

output "public_ip" {
  description = "Elastic IP of the host; it stays the same when the instance is replaced."
  value       = aws_eip.this.public_ip
}

output "private_ip" {
  description = "Private IPv4 address of the instance."
  value       = aws_instance.this.private_ip
}

output "security_group_id" {
  description = "ID of the host's security group (add rules for further scrape targets here)."
  value       = aws_security_group.this.id
}

output "data_volume_id" {
  description = "ID of the persistent data volume mounted at /var/lib/docker."
  value       = aws_ebs_volume.data.id
}

output "admin_user" {
  description = "Account to connect as with SSH and Ansible."
  value       = var.admin_user
}

output "ssh_command" {
  description = "SSH command for the admin account."
  value       = "ssh ${var.ssh_port == 22 ? "" : "-p ${var.ssh_port} "}${var.admin_user}@${aws_eip.this.public_ip}"
}
