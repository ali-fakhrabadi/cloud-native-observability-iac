variable "name" {
  description = "Name of the host: hostname, Name tag and prefix of every resource."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "VPC of the security group."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet of the instance (it needs a route to an internet gateway)."
  type        = string
}

variable "availability_zone" {
  description = "Availability Zone of subnet_id; the data volume is created there."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. The stack's memory limits add up to 3.5 GiB."
  type        = string
  default     = "t3.medium"
}

variable "architecture" {
  description = "CPU architecture of the Debian AMI: x86_64, or arm64 for Graviton instance types."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "ami_id" {
  description = "AMI to boot. Null uses the newest official Debian 12 AMI at creation time and keeps it."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "admin_user" {
  description = "Account cloud-init creates for SSH and Ansible (passwordless sudo, keys only)."
  type        = string
  default     = "deploy"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_user)) && var.admin_user != "root"
    error_message = "admin_user must be a valid Linux user name other than root."
  }
}

variable "ssh_public_keys" {
  description = "Public keys authorized for admin_user (OpenSSH format)."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "At least one SSH public key is required: the account has no password."
  }

  validation {
    condition = alltrue([
      for key in var.ssh_public_keys :
      can(regex("^(ssh-ed25519|sk-ssh-ed25519@openssh\\.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\\.com|ssh-rsa) [A-Za-z0-9+/]+={0,2}( [^\\n]*)?$", key))
    ])
    error_message = "Every entry must be one OpenSSH public key, such as \"ssh-ed25519 AAAA... user@host\"."
  }
}

variable "ssh_port" {
  description = "SSH port, matching linux_hardening_ssh_port in Ansible."
  type        = number
  default     = 22

  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535 && floor(var.ssh_port) == var.ssh_port
    error_message = "ssh_port must be a port number."
  }
}

variable "ssh_ingress_cidrs" {
  description = "IPv4 networks allowed to reach SSH. Empty closes SSH (use Session Manager)."
  type        = list(string)

  validation {
    condition = alltrue([
      for cidr in var.ssh_ingress_cidrs :
      can(cidrnetmask(cidr)) && try(cidrsubnet(cidr, 0, 0) == cidr, false) && !endswith(cidr, "/0")
    ])
    error_message = "ssh_ingress_cidrs must be IPv4 network addresses such as 198.51.100.10/32; 0.0.0.0/0 is refused."
  }
}

variable "grafana_ingress_cidrs" {
  description = "IPv4 networks allowed to reach Grafana on port 3000. Empty keeps it behind an SSH tunnel."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.grafana_ingress_cidrs :
      can(cidrnetmask(cidr)) && try(cidrsubnet(cidr, 0, 0) == cidr, false) && !endswith(cidr, "/0")
    ])
    error_message = "grafana_ingress_cidrs must be IPv4 network addresses such as 198.51.100.0/24; 0.0.0.0/0 is refused."
  }
}

variable "extra_egress_rules" {
  description = "Outbound TCP rules on top of HTTP and HTTPS, such as a scrape target: {description, port, cidr}."
  type = list(object({
    description = string
    port        = number
    cidr        = string
  }))
  default = []

  validation {
    condition = alltrue([
      for rule in var.extra_egress_rules :
      rule.port >= 1 && rule.port <= 65535 && can(cidrnetmask(rule.cidr)) && try(cidrsubnet(rule.cidr, 0, 0) == rule.cidr, false)
    ])
    error_message = "Every extra egress rule needs a port number and an IPv4 network address."
  }
}

variable "root_volume_size" {
  description = "Size of the root volume (OS and container images) in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.root_volume_size >= 8
    error_message = "root_volume_size must be at least 8 GiB (the Debian AMI size)."
  }
}

variable "data_volume_size" {
  description = "Size of the persistent data volume (/var/lib/docker: metrics, logs, dashboards) in GiB."
  type        = number
  default     = 30

  validation {
    condition     = var.data_volume_size >= 10 && var.data_volume_size <= 16384
    error_message = "data_volume_size must be between 10 and 16384 GiB."
  }
}

variable "data_volume_snapshot_retention" {
  description = "Daily snapshots of the data volume to keep. 0 disables snapshots."
  type        = number
  default     = 7

  validation {
    condition     = var.data_volume_snapshot_retention >= 0 && var.data_volume_snapshot_retention <= 1000
    error_message = "data_volume_snapshot_retention must be between 0 and 1000."
  }
}

variable "kms_key_arn" {
  description = "KMS key that encrypts both volumes. Null uses the account's default EBS key."
  type        = string
  default     = null
}

variable "ssm_enabled" {
  description = "Attach an instance profile for AWS Systems Manager Session Manager (shell access without SSH)."
  type        = bool
  default     = true
}

variable "termination_protection" {
  description = "Refuse API termination of the instance (terraform destroy then fails until it is disabled)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags added to every resource (on top of the provider's default_tags)."
  type        = map(string)
  default     = {}
}
