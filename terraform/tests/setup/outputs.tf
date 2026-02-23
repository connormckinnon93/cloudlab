# Outputs for test assertions — only values that tests actually reference.

# --- VM ---

output "vm_name" {
  value = proxmox_virtual_environment_vm.talos.name
}

output "vm_bios" {
  value = proxmox_virtual_environment_vm.talos.bios
}

output "vm_machine" {
  value = proxmox_virtual_environment_vm.talos.machine
}

output "vm_stop_on_destroy" {
  value = proxmox_virtual_environment_vm.talos.stop_on_destroy
}

output "vm_scsi_hardware" {
  value = proxmox_virtual_environment_vm.talos.scsi_hardware
}

output "vm_cpu" {
  value = proxmox_virtual_environment_vm.talos.cpu
}

output "vm_agent" {
  value = proxmox_virtual_environment_vm.talos.agent
}

output "vm_efi_disk" {
  value = proxmox_virtual_environment_vm.talos.efi_disk
}

output "vm_tpm_state" {
  value = proxmox_virtual_environment_vm.talos.tpm_state
}

output "vm_disk" {
  value = proxmox_virtual_environment_vm.talos.disk
}

output "vm_network_device" {
  value = proxmox_virtual_environment_vm.talos.network_device
}

output "vm_operating_system" {
  value = proxmox_virtual_environment_vm.talos.operating_system
}

output "vm_tags" {
  value = proxmox_virtual_environment_vm.talos.tags
}

# --- Image download ---

output "image_content_type" {
  value = proxmox_virtual_environment_download_file.talos_image.content_type
}

output "image_datastore_id" {
  value = proxmox_virtual_environment_download_file.talos_image.datastore_id
}

output "image_url" {
  value = proxmox_virtual_environment_download_file.talos_image.url
}

output "image_file_name" {
  value = proxmox_virtual_environment_download_file.talos_image.file_name
}

# --- Talos ---

output "talos_secrets_version" {
  value = talos_machine_secrets.this.talos_version
}

output "talos_machine_config_cluster_name" {
  value = data.talos_machine_configuration.controlplane.cluster_name
}

output "talos_machine_config_cluster_endpoint" {
  value = data.talos_machine_configuration.controlplane.cluster_endpoint
}

output "talos_machine_config_machine_type" {
  value = data.talos_machine_configuration.controlplane.machine_type
}

output "talos_client_config_endpoints" {
  value = data.talos_client_configuration.this.endpoints
}

output "talos_client_config_nodes" {
  value = data.talos_client_configuration.this.nodes
}

output "talos_config_patches" {
  value = talos_machine_configuration_apply.controlplane.config_patches
}

output "talos_bootstrap_node" {
  value = talos_machine_bootstrap.this.node
}

output "talos_kubeconfig_node" {
  value = talos_cluster_kubeconfig.this.node
}
