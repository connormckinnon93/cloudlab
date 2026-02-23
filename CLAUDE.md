# CLAUDE.md

Terraform project that provisions a single-node TalosOS Kubernetes cluster on Proxmox.

## Quick Reference

```bash
mise run setup            # First-time: install tools, tflint plugins, lefthook
mise run tf init          # Initialize Terraform
mise run tf plan          # Preview changes
mise run tf apply         # Apply changes
mise run config:export    # Encrypt talosconfig and kubeconfig
mise run config:decrypt   # Decrypt configs for local use
mise run check            # Run all validators: tf fmt, validate, lint, kustomize, kubeconform, gitleaks
mise run sops:edit        # Edit encrypted secrets (defaults to secrets.enc.json)
mise run flux:sops-key    # Load age key into cluster for SOPS decryption
```

## Repository Structure

- **`terraform/`** — All Terraform configuration
- **`terraform/output/`** — SOPS-encrypted talosconfig and kubeconfig
- **`docs/plans/`** — Design documents
- **`kubernetes/`** — Flux GitOps manifests (Kustomization hierarchy)
- **`.github/workflows/`** — GitHub Actions CI

## Key Files

| File | Purpose |
|------|---------|
| `.mise.toml` | Tool versions (terraform, talosctl, sops, age, kubectl, tflint, lefthook) and tasks |
| `.sops.yaml` | SOPS encryption rules — age key, file patterns |
| `terraform/versions.tf` | Required providers and version constraints |
| `terraform/variables.tf` | Variable declarations for VM and cluster config |
| `terraform/config.auto.tfvars` | Non-sensitive configuration (committed, auto-loaded by Terraform) |
| `terraform/main.tf` | Proxmox provider, VM resource, TalosOS image download |
| `terraform/talos.tf` | Talos machine config, bootstrap, kubeconfig retrieval |
| `terraform/outputs.tf` | Terraform outputs (vm_id, talosconfig, kubeconfig) |
| `terraform/secrets.enc.json` | SOPS-encrypted Proxmox API token |
| `terraform/.tflint.hcl` | tflint linter configuration |
| `lefthook.yml` | Git hooks (pre-commit: fmt, validate, lint; commit-msg: conventional commits) |
| `.github/workflows/check.yml` | GitHub Actions CI — runs `mise run check` on PRs |
| `kubernetes/kustomization.yaml` | Root Kustomize entry point — scopes `flux-system` Kustomization CRD to `flux-system/` only |
| `kubernetes/flux-system/` | Auto-generated Flux controllers and sync config |
| `kubernetes/flux-system/infrastructure.yaml` | Flux Kustomization CRD — reconciles `kubernetes/infrastructure/` |
| `kubernetes/flux-system/apps.yaml` | Flux Kustomization CRD — reconciles `kubernetes/apps/` |
| `kubernetes/infrastructure/kustomization.yaml` | Kustomize entry point for cluster services |
| `kubernetes/infrastructure/nfs-provisioner/` | NFS dynamic volume provisioner (Flux HelmRelease) |
| `kubernetes/infrastructure/kyverno/` | Kyverno policy engine (Flux HelmRelease) |
| `kubernetes/apps/kustomization.yaml` | Kustomize entry point for workloads (empty until step 14+) |

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
- Only truly secret values (API tokens) go in `secrets.enc.json`; network config goes in `config.auto.tfvars` (committed)
- Terraform state is local and gitignored — this is a single-operator homelab
- Use `mise run tf <subcommand>` for terraform operations

## Validation

```bash
mise run check            # Full suite: tf fmt, validate, lint, kustomize, kubeconform, gitleaks
mise run tf plan          # Verify Terraform changes before applying
flux check                # Verify Flux controllers are healthy
flux reconcile kustomization flux-system --with-source  # Force reconciliation
```

Three validation contexts: lefthook runs a fast subset on pre-commit (terraform fmt, kustomize build, gitleaks). `mise run check` runs the full suite on demand. GitHub Actions runs `mise run check` on every PR and gates merge.

## Platform Notes

- Proxmox host: Lenovo ThinkCentre M710q (i5-7th gen, 32 GB RAM, 512 GB NVMe)
- TalosOS v1.12.4 (SecureBoot + TPM-sealed LUKS2 encryption), extensions: qemu-guest-agent, nfs-utils
- VM uses fixed MAC address (`BC:24:11:CA:FE:01`) with DHCP reservation → `192.168.20.100`
- Synology NAS available at `nas.home` (`192.168.20.20`) for NFS persistent volumes (roadmap step 4)

## Implementation Notes

- **Talos 1.12 HostnameConfig**: Hostname uses the `HostnameConfig` multi-doc format (`apiVersion: v1alpha1, kind: HostnameConfig`) instead of the legacy `machine.network.hostname` field
- **VM IP bootstrapping**: `talos_machine_configuration_apply` connects to the VM's DHCP address (via QEMU guest agent `ipv4_addresses`), not the static IP being configured. Post-reboot resources (bootstrap, kubeconfig) use the static IP.
- **SOPS creation rules**: Files must match `\.enc\.(json|yaml)$` pattern. The `config:export` task writes directly to `.enc.yaml` filenames and uses `sops encrypt -i` (in-place)
- **Mise task args**: Use `usage` field with `var=#true` for optional arguments (not `arg()` template function)
- **Flux Kustomization hierarchy**: Flux CRDs (`infrastructure.yaml`, `apps.yaml`) live in `kubernetes/flux-system/` and are listed in its Kustomize `kustomization.yaml`. Target directories (`infrastructure/`, `apps/`) have their own Kustomize `kustomization.yaml` with resource lists. This avoids the naming conflict between Flux Kustomization CRDs and Kustomize's `kustomization.yaml`. The `flux-system` Kustomization CRD watches `path: ./kubernetes` — a root `kubernetes/kustomization.yaml` scopes it to `flux-system/` so it never encounters encrypted files meant for `infrastructure` or `apps`.
- **`mise run check` scope**: The `check` task runs from the project root (not `dir = "terraform"`). Terraform commands run in a subshell. Kubernetes validation is guarded by `[ -d kubernetes ]` and skips if the directory doesn't exist.
- **SOPS age key in cluster**: The `sops-age` Secret in `flux-system` provides the age private key to kustomize-controller for SOPS decryption. Created via `mise run flux:sops-key` — not managed by Terraform to keep the private key out of state. Re-run after cluster rebuild.
- **NFS provisioner pattern**: Infrastructure components follow a consistent directory structure under `kubernetes/infrastructure/`: dedicated namespace, HelmRepository, HelmRelease, and a Kustomize entry point. The parent `infrastructure/kustomization.yaml` references each component by directory name. This pattern repeats for ingress, cert-manager, and monitoring.
- **Kyverno image verification**: The ClusterPolicy verifies GHCR images (`ghcr.io/fluxcd/*`, `ghcr.io/kyverno/*`) in audit mode — unverified images are admitted but violations appear in PolicyReports (`kubectl get policyreport -A`). System namespaces (`kube-system`, `kyverno`) are excluded. Migrating to enforce mode requires reviewing audit results and potentially adding attestor entries for other signing authorities.
