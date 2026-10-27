output "public_ip" {
  description = "Elastic IP of the monitoring host."
  value       = module.monitoring_host.public_ip
}

output "ssh_command" {
  description = "SSH command for the admin account."
  value       = module.monitoring_host.ssh_command
}

output "grafana_tunnel_command" {
  description = "Forwards Grafana (bound to the host's loopback by default) to http://localhost:3000."
  value       = "ssh -N -L 3000:127.0.0.1:3000 ${module.monitoring_host.admin_user}@${module.monitoring_host.public_ip}"
}

output "ansible_inventory" {
  description = "Inventory for ansible/playbooks/site.yml, in the layout of ansible/inventories/example/hosts.yml."
  value = yamlencode({
    all = {
      children = {
        monitoring = {
          hosts = {
            (local.name) = {
              ansible_host = module.monitoring_host.public_ip
              ansible_user = module.monitoring_host.admin_user
            }
          }
        }
      }
    }
  })
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group with the VPC flow logs (rejected connections)."
  value       = module.network.flow_log_group_name
}
