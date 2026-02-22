# Cloudlab

Terraform configuration that provisions a single-node Kubernetes cluster on Proxmox using TalosOS.

## Prerequisites

- [Mise](https://mise.jdx.dev) installed
- A Proxmox node with API token configured
- An age keypair for SOPS encryption

## Setup

Install tools and configure git hooks:

```bash
mise run setup
```

Generate an age keypair (if you don't have one):

```bash
age-keygen -o .age-key.txt
```

Copy the public key from the output and add it to `.sops.yaml`.

Create the secrets file:

```bash
cat > terraform/secrets.enc.json <<'EOF'
{
  "proxmox_endpoint": "https://proxmox.local:8006",
  "proxmox_api_token": "user@pam!tokenid=secret-value",
  "talos_node_ip": "192.168.1.100",
  "gateway": "192.168.1.1"
}
EOF
sops encrypt -i terraform/secrets.enc.json
```

Generate a TalosOS schematic ID at [factory.talos.dev](https://factory.talos.dev) with these extensions:

- `siderolabs/qemu-guest-agent`
- `siderolabs/nfs-mount`

## Usage

```bash
mise run tf:init                              # Initialize Terraform
mise run tf:plan -- -var talos_schematic_id=<id>   # Preview changes
mise run tf:apply                             # Provision and bootstrap
mise run tf:use-configs                       # Install kubeconfig and talosconfig
kubectl get nodes                             # Verify
```

## Architecture

A single TalosOS VM runs on Proxmox as both the Kubernetes control plane and worker node. Terraform handles the full lifecycle:

1. Downloads the TalosOS image to Proxmox
2. Creates the VM with the image
3. Generates and applies TalosOS machine configuration
4. Bootstraps the single-node Kubernetes cluster
5. Retrieves and encrypts the kubeconfig and talosconfig

Secrets are encrypted with SOPS (age backend) and stored in git. The SOPS Terraform provider decrypts them inline during plan/apply — no manual decrypt step required.

## Tools

| Tool | Purpose |
|------|---------|
| Terraform | Infrastructure provisioning |
| talosctl | TalosOS management |
| SOPS + age | Secrets encryption |
| kubectl | Kubernetes access |
| tflint | Terraform linting |
| lefthook | Git pre-commit hooks |
| Mise | Tool version management and task runner |

## Future Work

- **etcd backups** — Periodic snapshots via `talosctl etcd snapshot` to the Synology NAS
- **NFS persistent volumes** — Mount Synology NAS exports for stateful workloads
- **Disk encryption** — LUKS2 encryption on STATE and EPHEMERAL partitions via Talos VolumeConfig
- **High availability** — Multi-node cluster with re-enabled discovery service
