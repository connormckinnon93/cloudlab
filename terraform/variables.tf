variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string
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
}

variable "gateway" {
  description = "Default gateway for the TalosOS node"
  type        = string
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
}

variable "talos_schematic_id" {
  description = "Schematic ID from factory.talos.dev (includes qemu-guest-agent and nfs-utils extensions)"
  type        = string
}

variable "vm_cpu_cores" {
  description = "Number of CPU cores for the VM"
  type        = number
  default     = 4
}

variable "vm_memory_mb" {
  description = "Memory in MiB for the VM"
  type        = number
  default     = 16384
}

variable "vm_disk_gb" {
  description = "Disk size in GiB for the VM"
  type        = number
  default     = 100
}
