terraform {
  required_version = "~> 1.14"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.96.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.3"
    }
  }
}
