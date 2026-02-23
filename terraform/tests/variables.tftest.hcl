# Variable validation tests use a helper module containing only variables.tf
# to avoid the ephemeral sops_file resource, which mock_provider does not support.

# Valid configuration plans successfully
run "valid_config" {
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
}

# Rejects non-HTTPS proxmox endpoint
run "rejects_http_endpoint" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "http://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }
  expect_failures = [var.proxmox_endpoint]
}

# Rejects invalid IP for talos_node_ip
run "rejects_invalid_ip" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "not-an-ip"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }
  expect_failures = [var.talos_node_ip]
}

# Rejects invalid talos_version format
run "rejects_bad_talos_version" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    talos_version      = "1.12.4"
  }
  expect_failures = [var.talos_version]
}

# Rejects invalid schematic_id
run "rejects_short_schematic" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "abc123"
  }
  expect_failures = [var.talos_schematic_id]
}

# Rejects CPU cores out of range
run "rejects_too_many_cores" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    vm_cpu_cores       = 32
  }
  expect_failures = [var.vm_cpu_cores]
}

# Rejects insufficient memory
run "rejects_low_memory" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    vm_memory_mb       = 512
  }
  expect_failures = [var.vm_memory_mb]
}

# Rejects small disk
run "rejects_small_disk" {
  command = plan
  module {
    source = "./tests/setup"
  }
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    vm_disk_gb         = 5
  }
  expect_failures = [var.vm_disk_gb]
}
