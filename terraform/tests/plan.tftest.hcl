# Plan-level assertions for the Terraform configuration.
# override_module skips the secrets module (ephemeral sops resource),
# letting us test the root module directly with a fake API token.

override_module {
  target = module.secrets
  outputs = {
    proxmox_api_token = "test@pam!test=00000000-0000-0000-0000-000000000000"
  }
}

run "default_plan" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  # --- VM: UEFI SecureBoot chain ---
  assert {
    condition     = proxmox_virtual_environment_vm.talos.bios == "ovmf"
    error_message = "VM BIOS must be ovmf for UEFI SecureBoot"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.machine == "q35"
    error_message = "VM must use q35 machine type for UEFI"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.efi_disk[0].type == "4m"
    error_message = "EFI disk must be 4m type"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.tpm_state[0].version == "v2.0"
    error_message = "TPM must be v2.0 for disk encryption"
  }

  # --- VM: performance ---
  assert {
    condition     = proxmox_virtual_environment_vm.talos.cpu[0].type == "host"
    error_message = "CPU type must be host for optimal single-node performance"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.scsi_hardware == "virtio-scsi-single"
    error_message = "SCSI hardware must be virtio-scsi-single for iothread support"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.disk[0].iothread == true
    error_message = "Disk must have iothread enabled"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.disk[0].discard == "on"
    error_message = "Disk must have discard enabled for thin provisioning"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.network_device[0].model == "virtio"
    error_message = "Network model must be virtio"
  }

  # --- VM: lifecycle and defaults ---
  assert {
    condition     = proxmox_virtual_environment_vm.talos.name == "talos-cp-1"
    error_message = "VM name should default to talos-cp-1"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.stop_on_destroy == true
    error_message = "VM must stop on destroy to avoid orphaned processes"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.agent[0].enabled == true
    error_message = "QEMU agent must be enabled for IP discovery"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.network_device[0].bridge == "vmbr0"
    error_message = "Network bridge must be vmbr0"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.talos.operating_system[0].type == "l26"
    error_message = "OS type must be l26 (Linux 2.6+)"
  }
  assert {
    condition     = toset(proxmox_virtual_environment_vm.talos.tags) == toset(["terraform", "talos", "kubernetes"])
    error_message = "VM must have terraform, talos, and kubernetes tags"
  }

  # --- Image download ---
  assert {
    condition     = proxmox_virtual_environment_download_file.talos_image.content_type == "iso"
    error_message = "Image content type must be iso"
  }
  assert {
    condition     = proxmox_virtual_environment_download_file.talos_image.datastore_id == "local"
    error_message = "ISO storage must use the local datastore"
  }
  assert {
    condition     = can(regex("secureboot\\.iso$", proxmox_virtual_environment_download_file.talos_image.url))
    error_message = "Image URL must reference the secureboot ISO"
  }

  # --- Talos machine configuration ---
  assert {
    condition     = data.talos_machine_configuration.controlplane.cluster_name == "cloudlab"
    error_message = "Cluster name must default to cloudlab"
  }
  assert {
    condition     = data.talos_machine_configuration.controlplane.cluster_endpoint == "https://192.168.20.100:6443"
    error_message = "Cluster endpoint must be https://<talos_node_ip>:6443"
  }
  assert {
    condition     = data.talos_machine_configuration.controlplane.machine_type == "controlplane"
    error_message = "Machine type must be controlplane"
  }

  # --- Talos client configuration ---
  assert {
    condition     = data.talos_client_configuration.this.endpoints == tolist(["192.168.20.100"])
    error_message = "Client config endpoints must match talos_node_ip"
  }
  assert {
    condition     = data.talos_client_configuration.this.nodes == tolist(["192.168.20.100"])
    error_message = "Client config nodes must match talos_node_ip"
  }

  # --- Bootstrap and kubeconfig use static IP, not DHCP ---
  assert {
    condition     = talos_machine_bootstrap.this.node == "192.168.20.100"
    error_message = "Bootstrap must use the static IP, not the DHCP address"
  }
  assert {
    condition     = talos_cluster_kubeconfig.this.node == "192.168.20.100"
    error_message = "Kubeconfig must use the static IP, not the DHCP address"
  }

  # --- Config patches: security-critical settings ---
  assert {
    condition     = length(talos_machine_configuration_apply.controlplane.config_patches) == 5
    error_message = "Expected 5 config patches"
  }
  assert {
    condition     = strcontains(talos_machine_configuration_apply.controlplane.config_patches[0], "installer-secureboot")
    error_message = "Install image must use the secureboot installer"
  }
  assert {
    condition     = strcontains(talos_machine_configuration_apply.controlplane.config_patches[1], "defaultRuntimeSeccompProfileEnabled")
    error_message = "Kubelet must have default seccomp profile enabled"
  }
  assert {
    condition     = strcontains(talos_machine_configuration_apply.controlplane.config_patches[1], "allowSchedulingOnControlPlanes")
    error_message = "Single-node cluster must allow scheduling on control planes"
  }
  assert {
    condition     = strcontains(talos_machine_configuration_apply.controlplane.config_patches[2], "HostnameConfig")
    error_message = "Hostname must use HostnameConfig kind (Talos 1.12 format)"
  }
  assert {
    condition     = strcontains(talos_machine_configuration_apply.controlplane.config_patches[3], "luks2") && strcontains(talos_machine_configuration_apply.controlplane.config_patches[3], "STATE")
    error_message = "STATE volume must use LUKS2 encryption"
  }
  assert {
    condition     = strcontains(talos_machine_configuration_apply.controlplane.config_patches[4], "luks2") && strcontains(talos_machine_configuration_apply.controlplane.config_patches[4], "EPHEMERAL")
    error_message = "EPHEMERAL volume must use LUKS2 encryption"
  }
  assert {
    condition     = strcontains(talos_machine_configuration_apply.controlplane.config_patches[4], "lockToState")
    error_message = "EPHEMERAL volume TPM key must be locked to state"
  }
}

run "explicit_version" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    talos_version      = "v1.12.4"
  }

  assert {
    condition     = proxmox_virtual_environment_download_file.talos_image.file_name == "talos-v1.12.4-metal-amd64-secureboot.iso"
    error_message = "Image filename must include the Talos version"
  }
  assert {
    condition     = talos_machine_secrets.this.talos_version == "v1.12.4"
    error_message = "Machine secrets must use the specified talos_version"
  }
  assert {
    condition     = strcontains(talos_machine_configuration_apply.controlplane.config_patches[0], "v1.12.4")
    error_message = "Install image must include the talos_version"
  }
}
