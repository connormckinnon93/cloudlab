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

Flux reconciles five Kustomization layers:

```
flux-system -> infrastructure -> infrastructure-config
                              -> cluster-policies -> apps
```

(infrastructure-config and cluster-policies both depend on infrastructure and reconcile in parallel)

### Why four layers after flux-system?

Flux's server-side dry-run rejects resources whose CRDs do not yet exist. Two categories of resources need separate layers:

- **infrastructure-config**: CRD-dependent resources (ClusterIssuer, Certificate, HTTPRoutes) that would deadlock infrastructure's dry-run if bundled with the HelmReleases that install those CRDs.
- **cluster-policies**: Kyverno ClusterPolicy resources that depend on Kyverno CRDs installed by infrastructure.

Both layers depend on infrastructure and reconcile in parallel.

### Infrastructure components

| Component | Purpose |
|-----------|---------|
| Gateway API | CRDs for Gateway and HTTPRoute resources (upstream GitRepository, commit-pinned) |
| cert-manager | Automates TLS certificates via Let's Encrypt DNS-01 (DigitalOcean) |
| Traefik | Ingress controller with Gateway API, hostPort binding on 80/443 |
| NFS provisioner | Dynamic PersistentVolumes from Synology NAS |
| Kyverno | Policy engine for image signature verification (audit mode) |
| Monitoring | Prometheus, Grafana, Alertmanager, Loki, Alloy for observability |
| AdGuard Home | DNS server with ad-blocking, backed by Unbound recursive resolver |
| CloudNativePG | PostgreSQL operator — manages clusters, backups, and failover |
| PostgreSQL | Shared database instance via CloudNativePG (single instance on NFS) |
| Authentik | Identity provider with Kubernetes-managed proxy outpost for SSO across all services |

### Cluster policies

Kyverno ClusterPolicies:

- **Image signature verification** — verifies GHCR image signatures (Flux, Kyverno) using Sigstore keyless attestation. Runs in audit mode; violations appear in PolicyReports (`kubectl get policyreport -A`).
- **Forward-auth injection** — auto-injects `traefik.io/middleware` annotation on all HTTPRoutes for Authentik forward-auth. Opt out with label `auth.catinthehack.ca/skip: "true"`.

A Traefik ForwardAuth Middleware (`middleware-forward-auth.yaml`) also lives in cluster-policies because it depends on Traefik CRDs installed by infrastructure.

### Apps

Each app follows the pattern: namespace, Deployment, Service, HTTPRoute, Kustomize entry point. The whoami app demonstrates this pattern. Register new apps in `kubernetes/apps/kustomization.yaml`.

## Ingress and TLS

Traefik binds to host ports 80 and 443 (no LoadBalancer needed on a single node). HTTP redirects to HTTPS at the entrypoint level.

cert-manager manages a wildcard Certificate for `*.catinthehack.ca`. The Certificate resource lives in `infrastructure-config/` and targets the traefik namespace so the TLS Secret is co-located with the Gateway. The ClusterIssuer uses DigitalOcean DNS-01 challenges.

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

The infrastructure-config Kustomization layer prevents CRD bootstrapping deadlocks. CRD-dependent resources (ClusterIssuer, Certificate, HTTPRoutes) live in a separate Flux Kustomization that waits for infrastructure to finish installing CRDs before dry-run checking.

After any cluster rebuild, re-run `mise run flux:sops-key` to restore the SOPS decryption key.

## Testing

Three tiers of tests, from fast/offline to slow/live:

| Tier | Command | What it covers |
|------|---------|----------------|
| Static | `mise run check` | terraform fmt, validate, tflint, `terraform test`, kyverno CLI tests, kustomize build, kubeconform, gitleaks |
| Security | `mise run security` | Trivy (misconfig), Pluto (deprecated APIs), kube-linter (best practices) |
| E2E | `mise run e2e` | Chainsaw tests against live cluster: Flux health, HelmRelease readiness, DNS resolution, TLS certificates, auth gateway |

`mise run test:all` combines static and security tiers. E2E runs separately because it requires a live cluster.

### Terraform tests

Native `terraform test` files in `terraform/tests/`. Variable validation tests check constraint enforcement. Plan-level tests use `override_module` to replace the SOPS secrets module with mock outputs, then assert on planned resource attributes. No apply — tests run without Proxmox or SOPS credentials.

### Kyverno CLI tests

Policy tests in `tests/kyverno/` verify the forward-auth injection ClusterPolicy. Two cases: injection on a standard HTTPRoute, and skip when the opt-out label is present. Runs offline via `kyverno test`.

### Chainsaw E2E tests

Integration tests in `tests/e2e/` run against the live cluster via Chainsaw. Five test cases: Flux controllers healthy, all HelmReleases ready, DNS resolves `*.catinthehack.ca`, wildcard TLS certificate valid, and auth gateway redirects unauthenticated requests.

## Validation Contexts

Three contexts run overlapping checks at different stages:

| Context | Trigger | Scope |
|---------|---------|-------|
| lefthook pre-commit | Every commit | terraform fmt, validate, tflint, kustomize build, gitleaks (staged) |
| `mise run check` | On demand | Full static suite: terraform + terraform test + kyverno test + kubernetes (kubeconform) + gitleaks |
| GitHub Actions | Every PR | `mise run check` (gates merge) |

kubeconform requires SOPS metadata to be stripped from kustomize output. An inline awk filter in the `mise run check` task handles this.
