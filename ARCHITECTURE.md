# Architecture

> ARCHITECTURE.md explains what the system is and why it is structured this way.
> See [CLAUDE.md](CLAUDE.md) for how to operate on the codebase.

Single-node TalosOS Kubernetes cluster on Proxmox, managed by Terraform and Flux GitOps.

## System Overview

Terraform provisions a TalosOS VM on Proxmox, bootstraps the Kubernetes control plane, and exports encrypted credentials. Flux watches this Git repository and reconciles all Kubernetes manifests automatically.

```
Proxmox (Terraform) -> TalosOS VM -> Kubernetes -> Flux GitOps -> Workloads
```

### Hardware

- Lenovo ThinkCentre M710q (i5-7th gen, 32 GB RAM, 512 GB NVMe)
- Synology NAS at 192.168.20.20 for NFS persistent volumes

### Networking

- VM static IP: 192.168.20.100/24, gateway 192.168.20.1
- Fixed MAC (BC:24:11:CA:FE:01) with DHCP reservation
- Domain: catinthehack.ca (wildcard certificate via Let's Encrypt)

## Terraform Pipeline

Terraform manages the VM lifecycle and cluster bootstrap:

1. Downloads TalosOS SecureBoot image from factory.talos.dev
2. Creates Proxmox VM (4 cores, 16 GB RAM, 100 GB disk, TPM 2.0)
3. Generates Talos machine secrets (certificates, tokens)
4. Applies machine configuration via DHCP address (QEMU guest agent)
5. VM reboots with static IP, LUKS2 disk encryption (TPM-sealed)
6. Bootstraps control plane at static IP
7. Exports encrypted talosconfig and kubeconfig

The DHCP-then-static IP transition matters: config apply uses the DHCP address, but bootstrap and kubeconfig use the static IP.

## Flux GitOps

Flux reconciles four Kustomization layers in a linear dependency chain:

```
flux-system -> infrastructure -> cluster-policies -> apps
```

### Why three layers after flux-system?

Flux's server-side dry-run rejects CRD-based resources (like Kyverno ClusterPolicy) before the HelmRelease that installs those CRDs has run. Policies must wait in a separate layer until infrastructure finishes installing CRDs.

### Infrastructure components

| Component | Purpose |
|-----------|---------|
| Gateway API | CRDs for Gateway and HTTPRoute resources (upstream GitRepository, commit-pinned) |
| cert-manager | Automates TLS certificates via Let's Encrypt DNS-01 (DigitalOcean) |
| Traefik | Ingress controller with Gateway API, hostPort binding on 80/443 |
| NFS provisioner | Dynamic PersistentVolumes from Synology NAS |
| Kyverno | Policy engine for image signature verification (audit mode) |

### Cluster policies

Kyverno ClusterPolicy verifies GHCR image signatures (Flux, Kyverno) using Sigstore keyless attestation. Runs in audit mode; violations appear in PolicyReports (`kubectl get policyreport -A`).

### Apps

Each app follows the pattern: namespace, Deployment, Service, HTTPRoute, Kustomize entry point. The whoami app demonstrates this pattern. Register new apps in `kubernetes/apps/kustomization.yaml`.

## Ingress and TLS

Traefik binds to host ports 80 and 443 (no LoadBalancer needed on a single node). HTTP redirects to HTTPS at the entrypoint level.

cert-manager manages a wildcard Certificate for `*.catinthehack.ca`. The Certificate resource lives in the traefik directory and targets the traefik namespace so the TLS Secret is co-located with the Gateway. The ClusterIssuer uses DigitalOcean DNS-01 challenges.

HTTPRoutes in app namespaces reference the Gateway with:

```yaml
parentRefs:
  - name: traefik-gateway
    namespace: traefik
```

The Gateway permits cross-namespace attachment via `namespacePolicy.from: All`.

## Secrets

All secrets are encrypted with SOPS using age keys:

- **Age private key**: `.age-key.txt` (gitignored, never committed)
- **In-cluster decryption**: `sops-age` Secret in flux-system (created via `mise run flux:sops-key`)
- **Encrypted files**: Match `\.enc\.(json|yaml)$` pattern

Flux's kustomize-controller decrypts SOPS resources at reconciliation time.

## Bootstrap (First Deploy)

On a fresh cluster, Flux's server-side dry-run rejects cert-manager Certificate and ClusterIssuer resources because the CRDs do not exist yet. This deadlocks the entire infrastructure Kustomization.

**Fix (one-time):**

1. `kubectl apply` the cert-manager HelmRepository and HelmRelease manually
2. Wait for cert-manager CRDs to install
3. Flux reconciles the rest automatically

Re-run `mise run flux:sops-key` after any cluster rebuild to restore the SOPS decryption key.

## Validation

Three contexts run overlapping checks at different stages:

| Context | Trigger | Scope |
|---------|---------|-------|
| lefthook pre-commit | Every commit | terraform fmt, validate, tflint, kustomize build, gitleaks (staged) |
| `mise run check` | On demand | Full suite: terraform + kubernetes (kubeconform) + gitleaks (full history) |
| GitHub Actions | Every PR | `mise run check` (gates merge) |

kubeconform requires SOPS metadata to be stripped from kustomize output. An inline awk filter in the `mise run check` task handles this.
