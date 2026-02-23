# Outputs for test assertions.

# --- VM attributes ---

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

output "vm_boot_order" {
  value = proxmox_virtual_environment_vm.talos.boot_order
}

# --- Image download attributes ---

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
