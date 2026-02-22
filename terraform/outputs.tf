output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.talos.vm_id
}

output "talosconfig" {
  description = "Talos client configuration"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubernetes kubeconfig"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}
