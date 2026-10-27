variable "name" {
  description = "Name prefix of every resource and its Name tag."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC, between /16 and /24."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    # cidrnetmask() only accepts IPv4; cidrsubnet(x, 0, 0) == x rejects host bits.
    condition = (
      can(cidrnetmask(var.vpc_cidr)) &&
      can(regex("/(1[6-9]|2[0-4])$", var.vpc_cidr)) &&
      try(cidrsubnet(var.vpc_cidr, 0, 0) == var.vpc_cidr, false)
    )
    error_message = "vpc_cidr must be an IPv4 network address between /16 and /24, such as 10.20.0.0/16."
  }
}

variable "subnet_cidr" {
  description = "IPv4 CIDR block of the public subnet. Defaults to the first /24 of the VPC."
  type        = string
  default     = null

  validation {
    condition = var.subnet_cidr == null || (
      can(cidrnetmask(var.subnet_cidr)) &&
      can(regex("/(1[6-9]|2[0-8])$", var.subnet_cidr)) &&
      try(cidrsubnet(var.subnet_cidr, 0, 0) == var.subnet_cidr, false)
    )
    error_message = "subnet_cidr must be an IPv4 network address between /16 and /28."
  }
}

variable "availability_zone" {
  description = "Availability Zone of the subnet. Defaults to the first available zone of the region."
  type        = string
  default     = null
}

variable "flow_logs_enabled" {
  description = "Record VPC flow logs in CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_logs_traffic_type" {
  description = "Traffic recorded in flow logs: REJECT (blocked connections, the security signal), ACCEPT or ALL."
  type        = string
  default     = "REJECT"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "flow_logs_retention_days" {
  description = "Days CloudWatch Logs keeps flow log records."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days must be a retention period CloudWatch Logs supports, such as 30, 90 or 365."
  }
}

variable "kms_key_arn" {
  description = "KMS key that encrypts the flow log group. Null keeps the CloudWatch Logs default encryption."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every resource (on top of the provider's default_tags)."
  type        = map(string)
  default     = {}
}
