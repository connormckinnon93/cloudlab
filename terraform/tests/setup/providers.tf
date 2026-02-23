# Test provider: replaces the ephemeral sops-derived API token
# with a hardcoded fake value for plan-level testing.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "test@pam!test=00000000-0000-0000-0000-000000000000"
  insecure  = true

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
