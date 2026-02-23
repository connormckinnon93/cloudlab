# Variable validation tests.

override_module {
  target = module.secrets
  outputs = {
    proxmox_api_token = "test@pam!test=00000000-0000-0000-0000-000000000000"
  }
}

run "valid_config" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }
}

run "rejects_http_endpoint" {
  command = plan
  variables {
    proxmox_endpoint   = "http://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }
  expect_failures = [var.proxmox_endpoint]
}

run "rejects_invalid_ip" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "not-an-ip"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }
  expect_failures = [var.talos_node_ip]
}

run "rejects_bad_talos_version" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    talos_version      = "1.12.4"
  }
  expect_failures = [var.talos_version]
}

run "rejects_short_schematic" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "abc123"
  }
  expect_failures = [var.talos_schematic_id]
}

run "rejects_too_many_cores" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    vm_cpu_cores       = 32
  }
  expect_failures = [var.vm_cpu_cores]
}

run "rejects_low_memory" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    vm_memory_mb       = 512
  }
  expect_failures = [var.vm_memory_mb]
}

run "rejects_small_disk" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
    vm_disk_gb         = 5
  }
  expect_failures = [var.vm_disk_gb]
}
