# The example environment end to end, with a mocked provider: both modules compose,
# and the outputs hand Ansible a usable inventory. No AWS account is involved.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-0aaaaaaaaaaaaaaaa"
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

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-central-1:123456789012:log-group:/vpc/observability-lab/flow-logs"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/observability-lab-20261027"
    }
  }

  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0123456789abcdef0"
    }
  }

  mock_resource "aws_eip" {
    defaults = {
      id        = "eipalloc-0123456789abcdef0"
      public_ip = "203.0.113.10"
    }
  }
}

variables {
  ssh_public_keys   = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7Cw5ej7R9CGhpYVY7xfCsA7eAE4JnZtPUT7JzxqZuy operator@example.com"]
  ssh_ingress_cidrs = ["198.51.100.10/32"]
}

run "plans_with_the_documented_inputs" {
  command = plan

  variables {
    grafana_ingress_cidrs = ["198.51.100.10/32"]
  }
}

run "composes_and_hands_over_to_ansible" {
  command = apply

  assert {
    condition = yamldecode(output.ansible_inventory) == {
      all = {
        children = {
          monitoring = {
            hosts = {
              observability-lab = {
                ansible_host = "203.0.113.10"
                ansible_user = "deploy"
              }
            }
          }
        }
      }
    }
    error_message = "ansible_inventory must put the host in the monitoring group with its Elastic IP and admin user."
  }

  assert {
    condition     = output.ssh_command == "ssh deploy@203.0.113.10"
    error_message = "ssh_command must target the Elastic IP."
  }

  assert {
    condition     = output.grafana_tunnel_command == "ssh -N -L 3000:127.0.0.1:3000 deploy@203.0.113.10"
    error_message = "grafana_tunnel_command must forward the host's loopback Grafana."
  }

  assert {
    condition     = output.flow_log_group_name == "/vpc/observability-lab/flow-logs"
    error_message = "Flow logs must be on in the example environment."
  }
}
