variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string

  validation {
    condition     = can(regex("^https://", var.proxmox_endpoint))
    error_message = "Must be an HTTPS URL."
  }
}

variable "proxmox_ssh_username" {
  description = "SSH username for the Proxmox host"
  type        = string
  default     = "terraform"
}

variable "proxmox_node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "talos_node_ip" {
  description = "IP address for the TalosOS node"
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.talos_node_ip))
    error_message = "Must be a valid IPv4 address."
  }
}

variable "gateway" {
  description = "Default gateway for the TalosOS node"
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.gateway))
    error_message = "Must be a valid IPv4 address."
  }
}

variable "vm_name" {
  description = "Name of the TalosOS VM"
  type        = string
  default     = "talos-cp-1"
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "cloudlab"
}

variable "talos_version" {
  description = "TalosOS version to deploy"
  type        = string
  default     = "v1.12.4"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.talos_version))
    error_message = "Must be a semver with 'v' prefix (e.g., v1.12.4)."
  }
}

variable "talos_schematic_id" {
  description = "Schematic ID from factory.talos.dev (includes qemu-guest-agent and nfs-utils extensions)"
  type        = string

  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.talos_schematic_id))
    error_message = "Must be a 64-character hex string."
  }
}

variable "vm_mac_address" {
  description = "Fixed MAC address for the TalosOS VM (for DHCP reservation)"
  type        = string
  default     = "BC:24:11:CA:FE:01"

  validation {
    condition     = can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", var.vm_mac_address))
    error_message = "Must be a MAC address (e.g., BC:24:11:CA:FE:01)."
  }
}

variable "vm_cpu_cores" {
  description = "Number of CPU cores for the VM"
  type        = number
  default     = 4

  validation {
    condition     = var.vm_cpu_cores >= 1 && var.vm_cpu_cores <= 16
    error_message = "Must be between 1 and 16."
  }
}

variable "vm_memory_mb" {
  description = "Memory in MiB for the VM"
  type        = number
  default     = 16384

  validation {
    condition     = var.vm_memory_mb >= 2048
    error_message = "Must be at least 2048 MiB (2 GB)."
  }
}

variable "vm_disk_gb" {
  description = "Disk size in GiB for the VM"
  type        = number
  default     = 100

  validation {
    condition     = var.vm_disk_gb >= 10
    error_message = "Must be at least 10 GiB."
  }
}
