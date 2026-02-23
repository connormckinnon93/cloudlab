# Test module: main.tf resources without the ephemeral sops provider.
# mock_provider does not support ephemeral resources, so we isolate
# the Proxmox resources here with a hardcoded fake API token.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "test@pam!test=00000000-0000-0000-0000-000000000000"
  insecure  = true

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}

# --- TalosOS Image ---

resource "proxmox_virtual_environment_download_file" "talos_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node_name
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64-secureboot.iso"
  file_name    = "talos-${var.talos_version}-metal-amd64-secureboot.iso"
}

# --- VM ---

resource "proxmox_virtual_environment_vm" "talos" {
  name        = var.vm_name
  description = "TalosOS control plane — managed by Terraform"
  tags        = ["terraform", "talos", "kubernetes"]
  node_name   = var.proxmox_node_name

  bios    = "ovmf"
  machine = "q35"

  boot_order      = ["scsi0"]
  scsi_hardware   = "virtio-scsi-single"
  stop_on_destroy = true

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  efi_disk {
    datastore_id      = "local-lvm"
    type              = "4m"
    pre_enrolled_keys = false
  }

  tpm_state {
    datastore_id = "local-lvm"
    version      = "v2.0"
  }

  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = var.vm_disk_gb
    iothread     = true
    discard      = "on"
  }

  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_image.id
    interface = "ide2"
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = var.vm_mac_address
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}
