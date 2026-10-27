provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "github.com/ali-fakhrabadi/cloud-native-observability-iac"
    }
  }
}

locals {
  name = "${var.project}-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  vpc_cidr = var.vpc_cidr
}

module "monitoring_host" {
  source = "../../modules/monitoring_host"

  name              = local.name
  vpc_id            = module.network.vpc_id
  subnet_id         = module.network.subnet_id
  availability_zone = module.network.availability_zone
  instance_type     = var.instance_type
  data_volume_size  = var.data_volume_size

  ssh_public_keys       = var.ssh_public_keys
  ssh_ingress_cidrs     = var.ssh_ingress_cidrs
  grafana_ingress_cidrs = var.grafana_ingress_cidrs
}
