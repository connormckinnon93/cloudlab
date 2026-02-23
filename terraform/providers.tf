# --- Secrets ---

module "secrets" {
  source = "./secrets"
}

# --- Talos ---

provider "talos" {}

# --- Proxmox ---

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = module.secrets.proxmox_api_token
  insecure  = true # Self-signed cert on homelab Proxmox

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
