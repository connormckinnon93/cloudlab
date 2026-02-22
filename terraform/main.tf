# --- Secrets ---

provider "sops" {}

# Ephemeral: API token stays out of Terraform state
ephemeral "sops_file" "secrets" {
  source_file = "${path.module}/secrets.enc.json"
}

# --- Proxmox ---

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = ephemeral.sops_file.secrets.data["proxmox_api_token"]
  insecure  = true # Self-signed cert on homelab Proxmox

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
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64.iso"
  file_name    = "talos-${var.talos_version}-metal-amd64.iso"
}

# --- VM ---

resource "proxmox_virtual_environment_vm" "talos" {
  name      = var.vm_name
  node_name = var.proxmox_node_name

  bios    = "ovmf"
  machine = "q35"

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
    datastore_id = "local-lvm"
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
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}
