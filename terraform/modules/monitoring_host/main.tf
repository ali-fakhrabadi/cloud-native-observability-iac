# One Debian 12 host for the observability stack. Terraform provisions it, cloud-init
# creates the admin account and mounts the data volume, Ansible does everything else
# (hardening, Docker, the stack).

data "aws_partition" "current" {}

data "aws_ami" "debian" {
  count = var.ami_id == null ? 1 : 0

  owners      = ["136693071363"] # Debian cloud team
  most_recent = true

  filter {
    name   = "name"
    values = ["debian-12-${var.architecture == "arm64" ? "arm64" : "amd64"}-*"]
  }

  filter {
    name   = "architecture"
    values = [var.architecture]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# The AMI found at creation time is recorded and kept, so a new Debian point release
# does not replace the host on the next apply. Move to a newer AMI on purpose:
#   terraform apply -replace='module.<name>.terraform_data.ami[0]'
resource "terraform_data" "ami" {
  count = var.ami_id == null ? 1 : 0

  input = data.aws_ami.debian[0].id

  lifecycle {
    ignore_changes = [input]
  }
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : terraform_data.ami[0].output

  # Docker keeps volumes (Prometheus, Loki, Grafana and Alertmanager data) here.
  data_mount_point = "/var/lib/docker"
  snapshot_tag     = "${var.name}-data"

  cloud_config = {
    hostname          = var.name
    preserve_hostname = false
    ssh_pwauth        = false
    disable_root      = true
    # Replaces the AMI's default user: one known account, in the group sshd allows.
    users = [{
      name                = var.admin_user
      groups              = ["sudo"]
      shell               = "/bin/bash"
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
      lock_passwd         = true
      ssh_authorized_keys = var.ssh_public_keys
    }]
    write_files = [{
      path        = "/usr/local/sbin/mount-data-volume"
      owner       = "root:root"
      permissions = "0755"
      content     = file("${path.module}/files/mount-data-volume.sh")
    }]
    runcmd = [["/usr/local/sbin/mount-data-volume", aws_ebs_volume.data.id, local.data_mount_point]]
  }
}

# --- Network access ----------------------------------------------------------------------

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "Monitoring host ${var.name}: SSH and Grafana from listed networks, web egress"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_ingress_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "SSH from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = var.ssh_port
  to_port           = var.ssh_port
  cidr_ipv4         = each.value

  tags = merge(var.tags, { Name = "${var.name}-ssh" })
}

resource "aws_vpc_security_group_ingress_rule" "grafana" {
  for_each = toset(var.grafana_ingress_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "Grafana from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
  cidr_ipv4         = each.value

  tags = merge(var.tags, { Name = "${var.name}-grafana" })
}

# Package repositories, container registries and notification APIs have no fixed
# addresses, so web egress cannot be narrowed further without a proxy. Security groups
# do not filter the Amazon DNS resolver, Time Sync Service or instance metadata.
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "web" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.this.id
  description       = "${upper(each.key)} to package repositories, registries and notification APIs"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_vpc_security_group_egress_rule" "extra" {
  for_each = { for rule in var.extra_egress_rules : "${rule.cidr}:${rule.port}" => rule }

  security_group_id = aws_security_group.this.id
  description       = each.value.description
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr

  tags = merge(var.tags, { Name = "${var.name}-egress" })
}

# --- Session Manager access ---------------------------------------------------------------

resource "aws_iam_role" "instance" {
  count = var.ssm_enabled ? 1 : 0

  name_prefix = "${substr(var.name, 0, 28)}-instance-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.ssm_enabled ? 1 : 0

  role       = aws_iam_role.instance[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  count = var.ssm_enabled ? 1 : 0

  name_prefix = "${substr(var.name, 0, 28)}-instance-"
  role        = aws_iam_role.instance[0].name

  tags = var.tags
}

# --- Instance -----------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  # The attribute is computed: null would keep a profile attached after ssm_enabled is
  # switched off, while "" detaches it.
  iam_instance_profile    = var.ssm_enabled ? aws_iam_instance_profile.this[0].name : ""
  disable_api_termination = var.termination_protection

  # cloud-init only runs on first boot: a changed configuration means a new instance.
  # The data volume and the Elastic IP move over to it.
  user_data                   = "#cloud-config\n${yamlencode(local.cloud_config)}"
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # One hop: processes on the host reach the metadata service, containers behind
    # Docker's NAT do not, so a compromised container gets no instance credentials.
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true

    tags = merge(var.tags, { Name = "${var.name}-root" })
  }

  tags = merge(var.tags, { Name = var.name })
}

# --- Persistent data ----------------------------------------------------------------------

# Outlives the instance: replacing the host keeps metrics, logs and dashboards.
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  type              = "gp3"
  size              = var.data_volume_size
  encrypted         = true
  kms_key_id        = var.kms_key_arn
  # A last snapshot is taken if the volume is ever destroyed.
  final_snapshot = true

  tags = merge(var.tags, { Name = "${var.name}-data", SnapshotPolicy = local.snapshot_tag })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
  # Stop the instance before detaching, so the filesystem is unmounted cleanly.
  stop_instance_before_detaching = true
}

resource "aws_iam_role" "snapshots" {
  count = var.data_volume_snapshot_retention > 0 ? 1 : 0

  name_prefix = "${substr(var.name, 0, 27)}-snapshots-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "snapshots" {
  count = var.data_volume_snapshot_retention > 0 ? 1 : 0

  role       = aws_iam_role.snapshots[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# Daily crash-consistent snapshots; Prometheus and Loki recover from them through
# their write-ahead logs.
resource "aws_dlm_lifecycle_policy" "data" {
  count = var.data_volume_snapshot_retention > 0 ? 1 : 0

  description        = "Daily snapshots of the ${var.name} data volume"
  execution_role_arn = aws_iam_role.snapshots[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { SnapshotPolicy = local.snapshot_tag }

    schedule {
      name      = "daily"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = var.data_volume_snapshot_retention
      }
    }
  }

  tags = var.tags
}

# --- Stable address -----------------------------------------------------------------------

resource "aws_eip" "this" {
  domain = "vpc"

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_eip_association" "this" {
  allocation_id = aws_eip.this.id
  instance_id   = aws_instance.this.id
}
