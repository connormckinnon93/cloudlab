# Decrypts SOPS-encrypted secrets and exposes them as ephemeral outputs.
# Wrapped in a module so tests can use override_module to skip decryption.

terraform {
  required_providers {
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.3"
    }
  }
}

ephemeral "sops_file" "this" {
  source_file = "${path.module}/../secrets.enc.json"
}

output "proxmox_api_token" {
  value     = ephemeral.sops_file.this.data["proxmox_api_token"]
  ephemeral = true
}
