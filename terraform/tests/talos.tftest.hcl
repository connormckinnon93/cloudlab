# Talos configuration tests for talos.tf
# Validates machine secrets, configuration, config patches, bootstrap, and
# kubeconfig resources at plan time.

# --- Machine secrets ---

run "machine_secrets_use_correct_talos_version" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    talos_version      = "v1.12.4"
  }

  assert {
    condition     = output.talos_secrets_version == "v1.12.4"
    error_message = "Machine secrets must use the specified talos_version"
  }
}

# --- Machine configuration data source ---

run "machine_config_uses_correct_cluster_name" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = output.talos_machine_config_cluster_name == "cloudlab"
    error_message = "Machine config cluster_name must default to cloudlab"
  }
}

run "machine_config_endpoint_uses_port_6443" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = output.talos_machine_config_cluster_endpoint == "https://192.168.20.100:6443"
    error_message = "Cluster endpoint must be https://<talos_node_ip>:6443"
  }
}

run "machine_config_type_is_controlplane" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = output.talos_machine_config_machine_type == "controlplane"
    error_message = "Machine type must be controlplane for single-node cluster"
  }
}

run "machine_config_version_matches_secrets" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    talos_version      = "v1.12.4"
  }

  assert {
    condition     = output.talos_machine_config_talos_version == output.talos_secrets_version
    error_message = "Machine config and secrets must use the same talos_version"
  }
}

# --- Client configuration data source ---

run "client_config_endpoints_match_node_ip" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = output.talos_client_config_endpoints == tolist(["192.168.20.100"])
    error_message = "Client config endpoints must contain the talos_node_ip"
  }

  assert {
    condition     = output.talos_client_config_nodes == tolist(["192.168.20.100"])
    error_message = "Client config nodes must contain the talos_node_ip"
  }
}

run "client_config_uses_cluster_name" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = output.talos_client_config_cluster_name == "cloudlab"
    error_message = "Client config cluster_name must match the cluster_name variable"
  }
}

# --- Config patches: install ---

run "config_patch_install_disk_is_sda" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[0], "/dev/sda")
    error_message = "Install disk must be /dev/sda"
  }
}

run "config_patch_install_image_uses_secureboot" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[0], "installer-secureboot")
    error_message = "Install image must use the secureboot installer"
  }
}

run "config_patch_install_image_includes_schematic_and_version" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    talos_version      = "v1.12.4"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[0], "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5")
    error_message = "Install image must include the talos_schematic_id"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[0], "v1.12.4")
    error_message = "Install image must include the talos_version"
  }
}

# --- Config patches: network ---

run "config_patch_network_uses_virtio_driver" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[0], "virtio_net")
    error_message = "Network interface must use virtio_net device selector"
  }
}

run "config_patch_network_static_ip_has_cidr" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[0], "192.168.20.100/24")
    error_message = "Static IP must include /24 CIDR suffix"
  }
}

run "config_patch_network_has_default_route" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[0], "0.0.0.0/0")
    error_message = "Network must include a default route (0.0.0.0/0)"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[0], "192.168.20.1")
    error_message = "Default route must use the gateway variable"
  }
}

# --- Config patches: kubelet and cluster ---

run "config_patch_kubelet_seccomp_enabled" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[1], "defaultRuntimeSeccompProfileEnabled")
    error_message = "Kubelet must have seccomp profile enabled"
  }
}

run "config_patch_scheduling_on_control_planes_allowed" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[1], "allowSchedulingOnControlPlanes")
    error_message = "Single-node cluster must allow scheduling on control planes"
  }
}

run "config_patch_discovery_disabled" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[1], "\"discovery\"")
    error_message = "Cluster patch must include discovery configuration"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[1], "\"enabled\": false")
    error_message = "Discovery must be disabled for single-node cluster"
  }
}

# --- Config patches: hostname (v1alpha1 multi-doc format) ---

run "config_patch_hostname_uses_v1alpha1_format" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[2], "HostnameConfig")
    error_message = "Hostname must use HostnameConfig kind (Talos 1.12 multi-doc format)"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[2], "v1alpha1")
    error_message = "HostnameConfig must use v1alpha1 apiVersion"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[2], "talos-cp-1")
    error_message = "Hostname must match the vm_name variable"
  }
}

# --- Config patches: disk encryption ---

run "config_patch_state_volume_uses_luks2_with_tpm" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[3], "VolumeConfig")
    error_message = "STATE volume must use VolumeConfig kind"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[3], "STATE")
    error_message = "Volume config must target the STATE partition"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[3], "luks2")
    error_message = "STATE volume must use LUKS2 encryption"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[3], "checkSecurebootStatusOnEnroll")
    error_message = "STATE volume TPM key must verify SecureBoot status"
  }
}

run "config_patch_ephemeral_volume_uses_luks2_with_tpm" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[4], "EPHEMERAL")
    error_message = "Volume config must target the EPHEMERAL partition"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[4], "luks2")
    error_message = "EPHEMERAL volume must use LUKS2 encryption"
  }

  assert {
    condition     = strcontains(output.talos_config_patches[4], "lockToState")
    error_message = "EPHEMERAL volume TPM key must be locked to state"
  }
}

run "config_patches_count_is_five" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = length(output.talos_config_patches) == 5
    error_message = "There must be exactly 5 config patches"
  }
}

# --- Bootstrap and kubeconfig use static IP ---

run "bootstrap_uses_static_ip_not_dhcp" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = output.talos_bootstrap_node == "192.168.20.100"
    error_message = "Bootstrap must use the static IP (talos_node_ip), not the DHCP address"
  }
}

run "kubeconfig_uses_static_ip_not_dhcp" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  assert {
    condition     = output.talos_kubeconfig_node == "192.168.20.100"
    error_message = "Kubeconfig must use the static IP (talos_node_ip), not the DHCP address"
  }
}

# --- Bootstrap and kubeconfig use a different IP than config_apply ---

run "bootstrap_and_kubeconfig_use_different_ip_than_config_apply" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  # Both bootstrap and kubeconfig must target the static IP consistently
  assert {
    condition     = output.talos_bootstrap_node == output.talos_kubeconfig_node
    error_message = "Bootstrap and kubeconfig must use the same node IP"
  }
}
