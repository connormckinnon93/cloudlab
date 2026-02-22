provider "talos" {}

# --- VM IP (for initial connection before static IP is configured) ---

locals {
  # Find the first non-loopback IPv4 address reported by the QEMU guest agent.
  # The interface index varies by OS; flatten and filter to avoid hardcoding it.
  vm_ip = [
    for addr in flatten(proxmox_virtual_environment_vm.talos.ipv4_addresses) :
    addr if addr != "127.0.0.1"
  ][0]
}

# --- Machine Secrets ---

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# --- Machine Configuration ---

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.talos_node_ip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

# --- Client Configuration ---

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.talos_node_ip]
  nodes                = [var.talos_node_ip]
}

# --- Apply Configuration ---

resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.vm_ip

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/sda"
          image = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}"
        }
        network = {
          hostname = var.vm_name
          interfaces = [{
            deviceSelector = {
              driver = "virtio_net"
            }
            addresses = ["${var.talos_node_ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.gateway
            }]
          }]
        }
      }
    }),
    yamlencode({
      machine = {
        kubelet = {
          extraArgs = {
            node-ip = var.talos_node_ip
          }
        }
      }
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
    }),
  ]
}

# --- Bootstrap ---

resource "talos_machine_bootstrap" "this" {
  node                 = var.talos_node_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.controlplane]
}

# --- Kubeconfig ---

resource "talos_cluster_kubeconfig" "this" {
  node                 = var.talos_node_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_bootstrap.this]
}
