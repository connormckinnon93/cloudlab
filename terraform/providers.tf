# --- Secrets ---

provider "sops" {}

# Ephemeral: API token stays out of Terraform state
ephemeral "sops_file" "secrets" {
  source_file = "${path.module}/secrets.enc.json"
}

# --- Proxmox ---

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = ephemeral.sops_file.secrets.data["proxmox_api_token"]
  insecure  = true # Self-signed cert on homelab Proxmox

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
