variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Project name, first part of every resource name and the Project tag."
  type        = string
  default     = "observability"
}

variable "environment" {
  description = "Environment name, second part of every resource name and the Environment tag."
  type        = string
  default     = "lab"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type of the monitoring host."
  type        = string
  default     = "t3.medium"
}

variable "data_volume_size" {
  description = "Size of the persistent data volume in GiB."
  type        = number
  default     = 30
}

variable "ssh_public_keys" {
  description = "OpenSSH public keys of the operators."
  type        = list(string)
}

variable "ssh_ingress_cidrs" {
  description = "IPv4 networks of the operators, allowed to reach SSH."
  type        = list(string)
}

variable "grafana_ingress_cidrs" {
  description = "IPv4 networks allowed to reach Grafana directly. Empty means SSH tunnel only."
  type        = list(string)
  default     = []
}
