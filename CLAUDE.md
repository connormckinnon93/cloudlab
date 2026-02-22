# CLAUDE.md

Terraform project that provisions a single-node TalosOS Kubernetes cluster on Proxmox.

## Quick Reference

```bash
mise run setup            # First-time: install tools, tflint plugins, lefthook
mise run tf:init          # Initialize Terraform
mise run tf:plan          # Preview changes
mise run tf:apply         # Apply and encrypt outputs
mise run tf:check         # Run fmt check, validate, lint
mise run tf:use-configs   # Decrypt configs to ~/.talos and ~/.kube
mise run sops:edit        # Edit encrypted secrets (defaults to secrets.enc.json)
```

## Repository Structure

- **`terraform/`** — All Terraform configuration
- **`terraform/output/`** — SOPS-encrypted talosconfig and kubeconfig
- **`docs/plans/`** — Design documents

## Key Files

| File | Purpose |
|------|---------|
| `.mise.toml` | Tool versions (terraform, talosctl, sops, age, kubectl, tflint, lefthook) and tasks |
| `.sops.yaml` | SOPS encryption rules — age key, file patterns |
| `terraform/versions.tf` | Required providers and version constraints |
| `terraform/variables.tf` | Variable declarations for VM and cluster config |
| `terraform/main.tf` | Proxmox provider, VM resource, TalosOS image download |
| `terraform/talos.tf` | Talos machine config, bootstrap, kubeconfig retrieval |
| `terraform/outputs.tf` | Terraform outputs (vm_id, talosconfig, kubeconfig) |
| `terraform/secrets.enc.json` | SOPS-encrypted Proxmox API token |
| `terraform/.tflint.hcl` | tflint linter configuration |
| `lefthook.yml` | Git pre-commit hooks (fmt, validate, lint) |

## Providers

| Provider | Purpose |
|----------|---------|
| `bpg/proxmox` | Proxmox VM and image management |
| `siderolabs/talos` | TalosOS configuration and bootstrap |
| `carlpett/sops` | Inline decryption of encrypted secrets |

## Secrets

- Encrypted with SOPS using age keys
- Age private key lives at `.age-key.txt` (gitignored, never committed)
- `SOPS_AGE_KEY_FILE` is set automatically by Mise
- Edit secrets: `mise run sops:edit` (decrypts, opens in `$EDITOR`, re-encrypts on save)
- Encrypt: `sops encrypt -i <file>`
- Decrypt: `sops decrypt <file>`

## Conventions

- Pin tool versions in `.mise.toml`, not system-wide
- Only truly secret values (API tokens) go in `secrets.enc.json`; network config goes in `terraform.tfvars` (gitignored)
- Terraform state is local and gitignored — this is a single-operator homelab
- Use `mise run tf:*` tasks, not raw `terraform` commands

## Validation

```bash
mise run tf:check         # fmt check + validate + tflint (also runs as pre-commit hook)
mise run tf:plan          # Verify changes before applying
```

Lefthook runs `tf:check` automatically on pre-commit for `.tf` file changes. Gitleaks scans all staged files for secrets (API keys, tokens, age private keys).

## Platform Notes

- Proxmox host: Lenovo ThinkCentre M710q (i5-7th gen, 32 GB RAM, 512 GB NVMe)
- TalosOS v1.12.4 with Secure Boot, extensions: qemu-guest-agent, nfs-utils
- Synology NAS available for NFS persistent volumes (future work)
