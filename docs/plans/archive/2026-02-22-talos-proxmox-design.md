# TalosOS on Proxmox — Design

## Goal

Provision a single TalosOS VM on a Proxmox node, bootstrap a single-node Kubernetes cluster, and store encrypted configs in git.

## Host

Lenovo ThinkCentre M710q (i5-7th gen, 32 GB RAM, 512 GB NVMe) running Proxmox. Operator workstation must have full-disk encryption (FileVault) enabled — Terraform state contains secrets in plaintext.

## Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | 1.14 | Infrastructure provisioning |
| talosctl | 1.12 | TalosOS management CLI |
| SOPS | 3.11 | Secrets encryption |
| age | 1.3 | Encryption backend for SOPS |
| kubectl | 1.32 | Kubernetes CLI (matches Talos 1.12's K8s) |
| tflint | 0.61 | Terraform linter |
| lefthook | 2.1 | Git hooks manager |
| gitleaks | 8.30 | Secret scanning |

## Terraform Providers

| Provider | Constraint | Purpose |
|----------|-----------|---------|
| `bpg/proxmox` | `~> 0.96.0` | VM creation, image download |
| `siderolabs/talos` | `~> 0.10.0` | Machine config, bootstrap, kubeconfig |
| `carlpett/sops` | `~> 1.3` | Inline secret decryption |

## Project Structure

```
cloudlab/
├── .mise.toml                    # Tool versions + task definitions
├── .sops.yaml                    # SOPS encryption rules
├── .gitleaks.toml                # Gitleaks rules (extends defaults + age key)
├── .gitignore
├── lefthook.yml                  # Git hooks (pre-commit + commit-msg)
├── terraform/
│   ├── .tflint.hcl              # tflint configuration
│   ├── versions.tf               # Required providers
│   ├── variables.tf              # Variable declarations
│   ├── config.auto.tfvars        # Non-sensitive config (committed)
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
| BIOS | OVMF (UEFI) | Required by TalosOS |
| Machine | q35 | Recommended by TalosOS Proxmox docs |
| CPU | 4 cores, host type | Half of 8 threads; host type for best performance |
| Memory | 16 GB | Half of 32 GB; plenty for K8s + services |
| Disk | 100 GB | ~20% of NVMe; room for images and PVs |

## Secrets Management

Only truly secret values are SOPS-encrypted. Network configuration lives in `config.auto.tfvars` (committed). The ephemeral SOPS provider keeps the API token out of Terraform state.

**Encrypted files:**
- `terraform/secrets.enc.json` — Proxmox API token only
- `terraform/output/talosconfig.enc.yaml` — Talos client config
- `terraform/output/kubeconfig.enc.yaml` — Kubernetes credentials

**Plaintext configuration:**
- `terraform/config.auto.tfvars` — Proxmox endpoint, node name, SSH username, node IP, gateway (committed)

**Age key** (`.age-key.txt`) is gitignored and never committed.

**Age key lifecycle:**
- **Generate:** `age-keygen -o .age-key.txt`, copy public key to `.sops.yaml`
- **Backup:** Store the private key in 1Password
- **Rotate:** Generate a new key, update `.sops.yaml`, run `sops updatekeys` on all encrypted files
- **Recover:** Restore `.age-key.txt` from 1Password backup

## Mise Tasks

| Task | Description |
|------|-------------|
| `setup` | Install tools, initialize tflint, install lefthook |
| `tf` | Run any terraform subcommand (e.g., `mise run tf plan`) |
| `check` | Run fmt check, validate, and tflint |
| `config:export` | Extract and encrypt talosconfig/kubeconfig (hidden) |
| `config:decrypt` | Decrypt configs for local use (scoped to project via mise env) |
| `sops:edit` | Edit encrypted secrets |
| `talos:upgrade` | In-place TalosOS upgrade via talosctl |

## Git Hooks (lefthook)

Pre-commit hooks run automatically:

| Hook | Scope | Command |
|------|-------|---------|
| `fmt-check` | `.tf` files | `terraform fmt -check` |
| `validate` | `.tf` files | `terraform validate` |
| `lint` | `.tf` files | `tflint` |
| `gitleaks` | All staged files | `gitleaks protect --staged` |
| `conventional` | Commit message | Conventional commits format |

Installed via `mise run setup`. Configuration in `lefthook.yml`.

## Workflow

1. Generate age key, encrypt secrets, generate Talos schematic ID
2. `mise run setup` — install tools, tflint plugins, lefthook hooks
3. `mise run tf init` — initialize providers
4. `mise run tf plan` — preview
5. `mise run tf apply && mise run config:export` — create VM, bootstrap, encrypt outputs
6. `mise run config:decrypt` — decrypt configs for local use
7. `kubectl get nodes` — verify

## Day-2 Operations

**TalosOS upgrades** use `talosctl`, not Terraform. Terraform manages initial provisioning; changing `talos_version` in Terraform would destroy and recreate the VM.

```bash
mise run talos:upgrade <schematic_id> <new_version>
```

**VM resource changes** (CPU, memory, disk) can be applied via Terraform by updating variables and running `mise run tf apply`.

**Recovery from partial apply:** If `terraform apply` fails mid-way (e.g., VM created but Talos bootstrap times out), re-run `mise run tf apply` — Talos resources are idempotent. Use `mise run tf state list` to inspect what was created and `mise run tf plan` to see the remaining delta.
