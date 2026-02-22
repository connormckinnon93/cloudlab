# TalosOS on Proxmox — Design

## Goal

Provision a single TalosOS VM on a Proxmox node, bootstrap a single-node Kubernetes cluster, and store encrypted configs in git.

## Host

Lenovo ThinkCentre M710q (i5-7th gen, 32 GB RAM, 512 GB NVMe) running Proxmox.

## Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | 1.14 | Infrastructure provisioning |
| talosctl | 1.12 | TalosOS management CLI |
| SOPS | 3.12 | Secrets encryption |
| age | 1.3 | Encryption backend for SOPS |
| kubectl | 1.32 | Kubernetes CLI (matches Talos 1.12's K8s) |
| tflint | 0.61 | Terraform linter |
| lefthook | 2.1 | Git hooks manager |
| gitleaks | 8.30 | Secret scanning |

## Terraform Providers

| Provider | Constraint | Purpose |
|----------|-----------|---------|
| `bpg/proxmox` | `~> 0.96` | VM creation, image download |
| `siderolabs/talos` | `~> 0.10` | Machine config, bootstrap, kubeconfig |
| `carlpett/sops` | `~> 1.3` | Inline secret decryption |

## Project Structure

```
cloudlab/
├── .mise.toml                    # Tool versions + task definitions
├── .sops.yaml                    # SOPS encryption rules
├── .gitignore
├── lefthook.yml                  # Git hooks (fmt, validate, lint)
├── terraform/
│   ├── .tflint.hcl              # tflint configuration
│   ├── versions.tf               # Required providers
│   ├── variables.tf              # Variable declarations
│   ├── main.tf                   # SOPS secrets, Proxmox provider, VM, image
│   ├── talos.tf                  # Talos config, bootstrap, kubeconfig
│   ├── outputs.tf                # talosconfig, kubeconfig, vm_id
│   ├── secrets.enc.json          # SOPS-encrypted secrets
│   └── output/
│       ├── talosconfig.enc.yaml  # Encrypted talosconfig
│       └── kubeconfig.enc.yaml   # Encrypted kubeconfig
```

## TalosOS Extensions

| Extension | Purpose |
|-----------|---------|
| `siderolabs/qemu-guest-agent` | Proxmox integration |
| `siderolabs/nfs-mount` | NFS volumes from Synology NAS |

Generate the schematic ID at `factory.talos.dev` with these extensions.

## VM Resources

| Resource | Value | Reasoning |
|----------|-------|-----------|
| CPU | 4 cores | Half of 8 threads; leaves headroom for Proxmox |
| Memory | 16 GB | Half of 32 GB; plenty for K8s + services |
| Disk | 100 GB | ~20% of NVMe; room for images and PVs |

## Secrets Management

SOPS encrypts secrets with age keys. The Terraform SOPS provider decrypts inline — no pre-decrypt step needed.

**Encrypted files:**
- `terraform/secrets.enc.json` — Proxmox API credentials, node IP, gateway
- `terraform/output/talosconfig.enc.yaml` — Talos client config
- `terraform/output/kubeconfig.enc.yaml` — Kubernetes credentials

**Age key** (`.age-key.txt`) is gitignored and never committed.

## Mise Tasks

| Task | Description |
|------|-------------|
| `setup` | Install tools, initialize tflint, install lefthook |
| `tf:init` | Initialize Terraform providers |
| `tf:plan` | Preview changes |
| `tf:apply` | Apply and encrypt outputs |
| `tf:check` | Run fmt check, validate, and tflint |
| `tf:export-configs` | Extract and encrypt talosconfig/kubeconfig |
| `tf:use-configs` | Decrypt configs to `~/.talos` and `~/.kube` |

## Git Hooks (lefthook)

Pre-commit hooks run automatically:

| Hook | Scope | Command |
|------|-------|---------|
| `fmt-check` | `.tf` files | `terraform fmt -check` |
| `validate` | `.tf` files | `terraform validate` |
| `lint` | `.tf` files | `tflint` |
| `gitleaks` | All staged files | `gitleaks protect --staged` |

Installed via `mise run setup`. Configuration in `lefthook.yml`.

## Workflow

1. Generate age key, encrypt secrets, generate Talos schematic ID
2. `mise run setup` — install tools, tflint plugins, lefthook hooks
3. `mise run tf:init` — initialize providers
4. `mise run tf:plan` — preview
5. `mise run tf:apply` — create VM, bootstrap, encrypt outputs
6. `mise run tf:use-configs` — install configs locally
7. `kubectl get nodes` — verify
