# Runs without AWS credentials (mocked provider). `command = apply` is used where an
# assertion needs values AWS would compute; the mocks in tests/mocks supply them.

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name              = "obs-test"
  vpc_id            = "vpc-0123456789abcdef0"
  subnet_id         = "subnet-0123456789abcdef0"
  availability_zone = "eu-central-1a"
  ssh_public_keys   = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7Cw5ej7R9CGhpYVY7xfCsA7eAE4JnZtPUT7JzxqZuy operator@example.com"]
  ssh_ingress_cidrs = ["198.51.100.10/32", "203.0.113.0/24"]
}

run "hardened_instance" {
  command = plan

  assert {
    condition = (
      aws_instance.this.metadata_options[0].http_endpoint == "enabled" &&
      aws_instance.this.metadata_options[0].http_tokens == "required" &&
      aws_instance.this.metadata_options[0].instance_metadata_tags == "disabled"
    )
    error_message = "The metadata service must require IMDSv2 session tokens."
  }

  assert {
    condition     = aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "Containers behind Docker's NAT must not reach the metadata service (hop limit 1)."
  }

  assert {
    condition = (
      aws_instance.this.root_block_device[0].encrypted &&
      aws_instance.this.root_block_device[0].volume_type == "gp3" &&
      aws_instance.this.root_block_device[0].volume_size == 20 &&
      aws_instance.this.root_block_device[0].delete_on_termination
    )
    error_message = "The root volume must be an encrypted 20 GiB gp3 volume."
  }

  assert {
    condition = (
      aws_ebs_volume.data.encrypted &&
      aws_ebs_volume.data.type == "gp3" &&
      aws_ebs_volume.data.size == 30 &&
      aws_ebs_volume.data.final_snapshot &&
      aws_ebs_volume.data.availability_zone == "eu-central-1a"
    )
    error_message = "The data volume must be an encrypted 30 GiB gp3 volume in the subnet's zone, snapshotted before deletion."
  }

  assert {
    condition     = aws_volume_attachment.data.device_name == "/dev/sdf" && aws_volume_attachment.data.stop_instance_before_detaching
    error_message = "The data volume must attach as /dev/sdf and detach only from a stopped instance."
  }

  assert {
    condition     = aws_instance.this.instance_type == "t3.medium" && aws_instance.this.user_data_replace_on_change && !aws_instance.this.disable_api_termination
    error_message = "Unexpected instance defaults."
  }
}

run "firewall" {
  command = plan

  assert {
    condition     = aws_security_group.this.vpc_id == var.vpc_id
    error_message = "The security group must be created in the given VPC."
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.ssh) == 2 &&
      toset([for rule in aws_vpc_security_group_ingress_rule.ssh : rule.cidr_ipv4]) == toset(var.ssh_ingress_cidrs) &&
      alltrue([for rule in aws_vpc_security_group_ingress_rule.ssh : rule.ip_protocol == "tcp" && rule.from_port == 22 && rule.to_port == 22])
    )
    error_message = "SSH (TCP 22) must be open to exactly the listed networks."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.grafana) == 0
    error_message = "Grafana must stay closed unless networks are listed."
  }

  assert {
    condition = (
      toset([for rule in aws_vpc_security_group_egress_rule.web : rule.from_port]) == toset([80, 443]) &&
      alltrue([for rule in aws_vpc_security_group_egress_rule.web : rule.cidr_ipv4 == "0.0.0.0/0"]) &&
      alltrue([for rule in aws_vpc_security_group_egress_rule.web : rule.ip_protocol == "tcp" && rule.from_port == rule.to_port])
    )
    error_message = "Egress must be limited to TCP 80 and 443."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.extra) == 0
    error_message = "No extra egress without extra_egress_rules."
  }
}

run "cloud_init_and_wiring" {
  command = apply

  assert {
    condition     = startswith(aws_instance.this.user_data, "#cloud-config\n")
    error_message = "user_data must be a cloud-config document."
  }

  assert {
    condition = jsonencode(yamldecode(aws_instance.this.user_data).users) == jsonencode([{
      name                = "deploy"
      groups              = ["sudo"]
      shell               = "/bin/bash"
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
      lock_passwd         = true
      ssh_authorized_keys = var.ssh_public_keys
    }])
    error_message = "cloud-init must create only the admin account: sudo group, locked password, the given keys."
  }

  assert {
    condition = (
      yamldecode(aws_instance.this.user_data).ssh_pwauth == false &&
      yamldecode(aws_instance.this.user_data).disable_root == true &&
      yamldecode(aws_instance.this.user_data).hostname == "obs-test"
    )
    error_message = "cloud-init must disable password and root logins and set the hostname."
  }

  assert {
    condition     = yamldecode(aws_instance.this.user_data).runcmd == [["/usr/local/sbin/mount-data-volume", "vol-0123456789abcdef0", "/var/lib/docker"]]
    error_message = "cloud-init must mount this instance's data volume at /var/lib/docker."
  }

  assert {
    condition = (
      yamldecode(aws_instance.this.user_data).write_files[0].path == "/usr/local/sbin/mount-data-volume" &&
      yamldecode(aws_instance.this.user_data).write_files[0].content == file("${path.module}/files/mount-data-volume.sh")
    )
    error_message = "cloud-init must install the mount script unchanged."
  }

  assert {
    condition     = aws_volume_attachment.data.instance_id == aws_instance.this.id && aws_volume_attachment.data.volume_id == aws_ebs_volume.data.id
    error_message = "The data volume must be attached to the instance."
  }

  assert {
    condition     = aws_eip_association.this.instance_id == aws_instance.this.id && aws_eip_association.this.allocation_id == aws_eip.this.id
    error_message = "The Elastic IP must be associated with the instance."
  }

  assert {
    condition = (
      aws_instance.this.iam_instance_profile == aws_iam_instance_profile.this[0].name &&
      aws_iam_role_policy_attachment.ssm[0].policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" &&
      jsondecode(aws_iam_role.instance[0].assume_role_policy).Statement[0].Principal == { Service = "ec2.amazonaws.com" }
    )
    error_message = "The instance must run with a Session Manager role and nothing else."
  }

  assert {
    condition = (
      aws_dlm_lifecycle_policy.data[0].execution_role_arn == aws_iam_role.snapshots[0].arn &&
      aws_dlm_lifecycle_policy.data[0].policy_details[0].target_tags == tomap({ SnapshotPolicy = "obs-test-data" }) &&
      aws_dlm_lifecycle_policy.data[0].policy_details[0].schedule[0].retain_rule[0].count == 7 &&
      aws_ebs_volume.data.tags.SnapshotPolicy == "obs-test-data"
    )
    error_message = "The data volume must be snapshotted daily, keeping 7 snapshots."
  }

  assert {
    condition = (
      output.ssh_command == "ssh deploy@203.0.113.10" &&
      output.public_ip == "203.0.113.10" &&
      output.data_volume_id == "vol-0123456789abcdef0" &&
      output.ami_id == "ami-0aaaaaaaaaaaaaaaa"
    )
    error_message = "Outputs must describe the host."
  }
}

run "grafana_and_extra_egress" {
  command = plan

  variables {
    grafana_ingress_cidrs = ["198.51.100.0/24"]
    extra_egress_rules    = [{ description = "Sentinel metrics", port = 8000, cidr = "10.0.1.20/32" }]
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.grafana) == 1 &&
      aws_vpc_security_group_ingress_rule.grafana["198.51.100.0/24"].from_port == 3000 &&
      aws_vpc_security_group_ingress_rule.grafana["198.51.100.0/24"].to_port == 3000
    )
    error_message = "Grafana (TCP 3000) must open to the listed network."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.extra["10.0.1.20/32:8000"].from_port == 8000 &&
      aws_vpc_security_group_egress_rule.extra["10.0.1.20/32:8000"].description == "Sentinel metrics"
    )
    error_message = "Extra egress rules must be created as given."
  }
}

run "custom_ssh_port" {
  command = apply

  variables {
    ssh_port = 2222
  }

  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.ssh : rule.from_port == 2222 && rule.to_port == 2222])
    error_message = "The SSH rule must follow ssh_port."
  }

  assert {
    condition     = output.ssh_command == "ssh -p 2222 deploy@203.0.113.10"
    error_message = "ssh_command must include a non-default port."
  }
}

run "ssh_closed_for_session_manager_only" {
  command = plan

  variables {
    ssh_ingress_cidrs = []
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.ssh) == 0
    error_message = "No SSH rule may exist without ssh_ingress_cidrs."
  }
}

# Plans against the state of the earlier applies, where the features were on.
run "optional_features_switched_off" {
  command = plan

  variables {
    ssm_enabled                    = false
    data_volume_snapshot_retention = 0
    termination_protection         = true
  }

  assert {
    condition = (
      aws_instance.this.iam_instance_profile == "" &&
      length(aws_iam_role.instance) == 0 &&
      length(aws_iam_instance_profile.this) == 0
    )
    error_message = "Switching Session Manager off must detach the instance profile and delete the role."
  }

  assert {
    condition     = length(aws_dlm_lifecycle_policy.data) == 0 && length(aws_iam_role.snapshots) == 0
    error_message = "Retention 0 must remove the snapshot policy and its role."
  }

  assert {
    condition     = aws_instance.this.disable_api_termination
    error_message = "termination_protection must enable API termination protection."
  }
}

run "arm64" {
  command = plan

  variables {
    instance_type = "t4g.medium"
    architecture  = "arm64"
  }

  assert {
    condition     = one([for filter in data.aws_ami.debian[0].filter : filter.values if filter.name == "name"]) == toset(["debian-12-arm64-*"])
    error_message = "Graviton instances must look up the arm64 Debian AMI."
  }
}

run "rejects_ssh_open_to_the_internet" {
  command = plan

  variables {
    ssh_ingress_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.ssh_ingress_cidrs]
}

run "rejects_cidr_with_host_bits" {
  command = plan

  variables {
    ssh_ingress_cidrs = ["198.51.100.10/24"]
  }

  expect_failures = [var.ssh_ingress_cidrs]
}

run "rejects_ipv6_cidr" {
  command = plan

  variables {
    ssh_ingress_cidrs = ["2001:db8::/64"]
  }

  expect_failures = [var.ssh_ingress_cidrs]
}

run "rejects_grafana_open_to_the_internet" {
  command = plan

  variables {
    grafana_ingress_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.grafana_ingress_cidrs]
}

run "rejects_missing_keys" {
  command = plan

  variables {
    ssh_public_keys = []
  }

  expect_failures = [var.ssh_public_keys]
}

run "rejects_private_key_material" {
  command = plan

  variables {
    ssh_public_keys = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
  }

  expect_failures = [var.ssh_public_keys]
}

run "rejects_two_keys_in_one_entry" {
  command = plan

  variables {
    ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7Cw5ej7R9CGhpYVY7xfCsA7eAE4JnZtPUT7JzxqZuy a\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7Cw5ej7R9CGhpYVY7xfCsA7eAE4JnZtPUT7JzxqZuy b"]
  }

  expect_failures = [var.ssh_public_keys]
}

run "rejects_root_admin" {
  command = plan

  variables {
    admin_user = "root"
  }

  expect_failures = [var.admin_user]
}

run "rejects_malformed_ami" {
  command = plan

  variables {
    ami_id = "debian-12"
  }

  expect_failures = [var.ami_id]
}

run "rejects_unknown_architecture" {
  command = plan

  variables {
    architecture = "riscv64"
  }

  expect_failures = [var.architecture]
}

run "rejects_root_volume_below_ami_size" {
  command = plan

  variables {
    root_volume_size = 4
  }

  expect_failures = [var.root_volume_size]
}
