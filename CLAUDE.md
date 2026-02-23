# CLAUDE.md

> CLAUDE.md explains how to operate on the codebase.
> See [ARCHITECTURE.md](ARCHITECTURE.md) for what the system is and why it is structured this way.

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
| `kubernetes/flux-system/cluster-policies.yaml` | Flux Kustomization CRD — reconciles `kubernetes/cluster-policies/` (depends on infrastructure) |
| `kubernetes/infrastructure/kustomization.yaml` | Kustomize entry point for cluster services |
| `kubernetes/infrastructure/nfs-provisioner/` | NFS dynamic volume provisioner (Flux HelmRelease) |
| `kubernetes/infrastructure/kyverno/` | Kyverno policy engine (Flux HelmRelease) |
| `kubernetes/cluster-policies/` | Kyverno ClusterPolicies (applied after infrastructure CRDs exist) |
| `kubernetes/apps/kustomization.yaml` | Kustomize entry point for workloads |
| `kubernetes/apps/whoami/` | Smoke test app — validates ingress, TLS, and Gateway routing |
| `kubernetes/infrastructure/gateway-api/` | Gateway API CRDs (upstream GitRepository, commit-pinned) |
| `kubernetes/infrastructure/cert-manager/` | cert-manager with DNS-01 via DigitalOcean |
| `kubernetes/infrastructure/traefik/` | Traefik ingress with Gateway API, wildcard TLS |
| `kubernetes/infrastructure/monitoring/` | Observability stack — kube-prometheus-stack, Loki, Alloy, alerting |

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

## Implementation Notes

- **Talos 1.12 HostnameConfig**: Hostname uses the `HostnameConfig` multi-doc format (`apiVersion: v1alpha1, kind: HostnameConfig`) instead of the legacy `machine.network.hostname` field
- **VM IP bootstrapping**: `talos_machine_configuration_apply` connects to the VM's DHCP address (via QEMU guest agent `ipv4_addresses`), not the static IP being configured. Post-reboot resources (bootstrap, kubeconfig) use the static IP.
- **SOPS creation rules**: Files must match `\.enc\.(json|yaml)$` pattern. The `config:export` task writes directly to `.enc.yaml` filenames and uses `sops encrypt -i` (in-place)
- **Mise task args**: Use `usage` field with `var=#true` for optional arguments (not `arg()` template function)
- **Flux Kustomization hierarchy**: Flux CRDs (`infrastructure.yaml`, `cluster-policies.yaml`, `apps.yaml`) live in `kubernetes/flux-system/` and are listed in its Kustomize `kustomization.yaml`. Target directories (`infrastructure/`, `cluster-policies/`, `apps/`) have their own Kustomize `kustomization.yaml` with resource lists. The dependency chain is `flux-system → infrastructure → cluster-policies → apps` (linear chain). Policies are separated from infrastructure because CRD-based resources (like Kyverno ClusterPolicy) cannot be applied in the same Kustomization as the HelmRelease that installs their CRDs — Flux's server-side dry-run rejects unknown kinds, deadlocking the reconciliation.
- **`mise run check` scope**: The `check` task runs from the project root (not `dir = "terraform"`). Terraform commands run in a subshell. Kubernetes validation is guarded by `[ -d kubernetes ]` and skips if the directory doesn't exist.
- **SOPS age key in cluster**: The `sops-age` Secret in `flux-system` provides the age private key to kustomize-controller for SOPS decryption. Created via `mise run flux:sops-key` — not managed by Terraform to keep the private key out of state. Re-run after cluster rebuild.
- **NFS provisioner pattern**: Infrastructure components follow a consistent directory structure under `kubernetes/infrastructure/`: dedicated namespace, HelmRepository, HelmRelease, and a Kustomize entry point. The parent `infrastructure/kustomization.yaml` references each component by directory name. This pattern repeats for ingress, cert-manager, and monitoring.
- **Kyverno image verification**: The ClusterPolicy verifies GHCR images (`ghcr.io/fluxcd/*`, `ghcr.io/kyverno/*`) in audit mode — unverified images are admitted but violations appear in PolicyReports (`kubectl get policyreport -A`). System namespaces (`kube-system`, `kyverno`) are excluded. Migrating to enforce mode requires reviewing audit results and potentially adding attestor entries for other signing authorities.
- **Gateway API CRDs**: CRDs fetched from upstream `kubernetes-sigs/gateway-api` via Flux GitRepository source, pinned to a commit SHA in `kubernetes/infrastructure/gateway-api/gitrepository.yaml`. Upgrade by changing the commit (look up the SHA for the desired release tag).
- **cert-manager DNS-01**: DigitalOcean DNS provider for Let's Encrypt challenges. The SOPS-encrypted API token (`secret.enc.yaml`) lives in the cert-manager directory. The ClusterIssuer is cluster-scoped; cert-manager looks for the token Secret in the cert-manager namespace.
- **Traefik Gateway API**: Gateway and GatewayClass created by the Helm chart (`gateway.enabled: true`). Default Gateway name is `traefik-gateway`. HTTPRoutes from any namespace can attach (`namespacePolicy.from: All`). Dashboard accessed via `kubectl port-forward deploy/traefik 8080:8080 -n traefik` (must target the Deployment, not the Service — chart v38 doesn't expose port 8080 on the Service or pass `api.insecure` to Traefik).
- **hostPort binding**: Traefik binds to node ports 80 and 443 via hostPort (mapped from container ports 8000 and 8443). No LoadBalancer or MetalLB needed. HTTP→HTTPS redirect at the entrypoint level, before Gateway routing. The traefik namespace requires `pod-security.kubernetes.io/enforce: privileged` because TalosOS enforces `baseline` PSA by default.
- **Wildcard certificate**: The Certificate resource lives in the traefik namespace so the TLS Secret is co-located with the Gateway that references it. cert-manager renews automatically 30 days before expiry.
- **SOPS in kubernetes/**: The `mise run check` task strips `sops:` metadata from kustomize output before kubeconform validation (awk filter). Flux's kustomize-controller decrypts SOPS files at reconciliation time.
- **Flux CRD bootstrapping**: On first deployment, Flux's server-side dry-run rejects Certificate/ClusterIssuer resources because cert-manager CRDs don't exist yet. This deadlocks the entire infrastructure Kustomization — the HelmRelease that installs the CRDs can't be applied either. Fix: manually `kubectl apply` the cert-manager HelmRepository and HelmRelease, wait for CRDs, then Flux reconciles the rest. Only needed once per cluster bootstrap.
- **Traefik chart v38 redirect syntax**: The `redirectTo` property was removed from the values schema. Use `redirections.entryPoint.to` instead (see `ports.web.redirections` in helmrelease.yaml).
- **Cross-namespace HTTPRoute**: Routes in app namespaces reference the Gateway with `parentRefs: [{name: traefik-gateway, namespace: traefik}]`. The Gateway permits this via `namespacePolicy.from: All`. Each app needs its own subdomain under `*.catinthehack.ca` — the wildcard cert covers all of them.
- **App deployment pattern**: The whoami app (`kubernetes/apps/whoami/`) is the template for future services: namespace, Deployment, Service, HTTPRoute, and a Kustomize entry point. Register each app directory in `kubernetes/apps/kustomization.yaml`.
- **Observability namespace**: All monitoring components (Prometheus, Grafana, Alertmanager, Loki, Alloy) share the `monitoring` namespace in a single `kubernetes/infrastructure/monitoring/` directory. This deviates from the one-namespace-per-component pattern — these components form a tightly coupled system with shared HelmRepositories and cross-references.
- **Grafana datasource auto-discovery**: kube-prometheus-stack's Grafana sidecar watches for ConfigMaps labeled `grafana_datasource: "1"` in the monitoring namespace. Loki registers via this mechanism (`grafana-datasource-loki.yaml`).
- **Alertmanager Pushover credentials**: Mounted from the `monitoring-secrets` Secret via `alertmanager.alertmanagerSpec.secrets` in kube-prometheus-stack values. Credentials read from files at `/etc/alertmanager/secrets/monitoring-secrets/`. Edit with `mise run sops:edit kubernetes/infrastructure/monitoring/secret.enc.yaml`.
- **Alloy log collection**: Uses `loki.source.kubernetes` (Kubernetes API-based) not file-based tailing. No `/var/log` mount needed — correct for TalosOS's immutable filesystem. River config embedded in HelmRelease values via `alloy.configMap.content`.
- **Flux notification-controller**: Provider (type: alertmanager) and Alert resources in `flux-system/` push GitOps events to Alertmanager. Alert includes cross-namespace event sources for both `flux-system` and `monitoring`. Second signal path alongside Prometheus scraping Flux metrics via PodMonitor.
- **Flux metrics PodMonitor**: Lives in `monitoring` namespace, targets Flux controller pods in `flux-system` via `namespaceSelector`. Required for the FluxReconciliationFailure custom alert rule.
- **Loki storage**: Filesystem-backed TSDB in single-binary mode on NFS. Known risk: NFS's weaker fsync semantics. Fallback: switch to hostPath on local NVMe if corruption occurs.
- **Loki retention**: Requires both `limits_config.retention_period` and `compactor.retention_enabled: true`. Without the compactor flag, expired data is never deleted.
- **Exposed UIs without auth**: Grafana has built-in login. Prometheus, Alertmanager, and Alloy have no authentication — first candidates for the auth gateway (step 12).
- **flux-system/kustomization.yaml manual additions**: Contains custom resources (infrastructure.yaml, apps.yaml, cluster-policies.yaml, provider-alertmanager.yaml, alert-flux.yaml) that must be re-added after `flux bootstrap` operations.
