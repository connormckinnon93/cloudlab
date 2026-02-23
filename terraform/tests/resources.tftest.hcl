# Resource configuration tests for main.tf
# Uses a shared helper module to isolate Proxmox resources from the ephemeral
# sops provider, which mock_provider does not support.

# --- VM resource: UEFI and machine type ---

run "vm_uses_uefi_bios" {
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
    condition     = output.vm_bios == "ovmf"
    error_message = "VM BIOS must be ovmf for UEFI SecureBoot"
  }
}

run "vm_uses_q35_machine" {
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
    condition     = output.vm_machine == "q35"
    error_message = "VM must use q35 machine type for UEFI"
  }
}

# --- VM resource: defaults ---

run "vm_name_defaults_to_talos_cp_1" {
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
    condition     = output.vm_name == "talos-cp-1"
    error_message = "VM name should default to talos-cp-1"
  }
}

# --- VM resource: lifecycle and agent ---

run "vm_stops_on_destroy" {
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
    condition     = output.vm_stop_on_destroy == true
    error_message = "VM must stop on destroy to avoid orphaned processes"
  }
}

run "vm_has_qemu_agent_enabled" {
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
    condition     = output.vm_agent[0].enabled == true
    error_message = "QEMU agent must be enabled for IP discovery"
  }
}

# --- VM resource: CPU and hardware ---

run "vm_uses_host_cpu_type" {
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
    condition     = output.vm_cpu[0].type == "host"
    error_message = "CPU type must be host for optimal single-node performance"
  }
}

run "vm_uses_virtio_scsi" {
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
    condition     = output.vm_scsi_hardware == "virtio-scsi-single"
    error_message = "SCSI hardware must be virtio-scsi-single for iothread support"
  }
}

# --- VM resource: firmware and security ---

run "vm_efi_disk_type_is_4m" {
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
    condition     = output.vm_efi_disk[0].type == "4m"
    error_message = "EFI disk must be 4m type"
  }
}

run "vm_tpm_version_is_v2" {
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
    condition     = output.vm_tpm_state[0].version == "v2.0"
    error_message = "TPM must be v2.0 for TalosOS disk encryption"
  }
}

# --- VM resource: disk configuration ---

run "vm_disk_has_iothread_and_discard" {
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
    condition     = output.vm_disk[0].iothread == true
    error_message = "Disk must have iothread enabled"
  }

  assert {
    condition     = output.vm_disk[0].discard == "on"
    error_message = "Disk must have discard enabled for thin provisioning"
  }
}

# --- VM resource: network ---

run "vm_network_uses_virtio_on_vmbr0" {
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
    condition     = output.vm_network_device[0].bridge == "vmbr0"
    error_message = "Network bridge must be vmbr0 (Proxmox default)"
  }

  assert {
    condition     = output.vm_network_device[0].model == "virtio"
    error_message = "Network model must be virtio for optimal performance"
  }
}

# --- VM resource: operating system ---

run "vm_os_type_is_linux" {
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
    condition     = output.vm_operating_system[0].type == "l26"
    error_message = "OS type must be l26 (Linux 2.6+)"
  }
}

# --- Image download resource ---

run "image_downloads_secureboot_iso" {
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
    condition     = output.image_content_type == "iso"
    error_message = "Image content type must be iso"
  }

  assert {
    condition     = output.image_datastore_id == "local"
    error_message = "ISO storage must use the local datastore"
  }

  assert {
    condition     = can(regex("secureboot\\.iso$", output.image_url))
    error_message = "Image URL must reference the secureboot ISO"
  }
}

# --- Image download: filename format ---

run "image_filename_includes_version" {
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
    condition     = output.image_file_name == "talos-v1.12.4-metal-amd64-secureboot.iso"
    error_message = "Image filename must include the Talos version"
  }
}

# --- VM resource: tags ---

run "vm_has_expected_tags" {
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
    condition     = contains(output.vm_tags, "terraform")
    error_message = "VM must have terraform tag"
  }

  assert {
    condition     = contains(output.vm_tags, "talos")
    error_message = "VM must have talos tag"
  }

  assert {
    condition     = contains(output.vm_tags, "kubernetes")
    error_message = "VM must have kubernetes tag"
  }
}
