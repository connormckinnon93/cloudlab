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
| `.mise.toml` | Tool versions (terraform, talosctl, sops, age, kubectl, tflint, lefthook, gitleaks, kustomize, kubeconform, flux2, helm) and tasks |
| `.sops.yaml` | SOPS encryption rules — age key, file patterns |
| `terraform/versions.tf` | Required providers and version constraints |
| `terraform/variables.tf` | Variable declarations for VM and cluster config |
| `terraform/config.auto.tfvars` | Non-sensitive configuration (committed, auto-loaded by Terraform) |
| `terraform/providers.tf` | Secrets module + Proxmox provider configuration |
| `terraform/secrets/main.tf` | SOPS decryption wrapped in module (tests use `override_module` to skip) |
| `terraform/tests/` | Terraform native tests — variable validation and plan-level assertions |
| `terraform/main.tf` | VM resource, TalosOS image download |
| `terraform/talos.tf` | Talos machine config, bootstrap, kubeconfig retrieval |
| `terraform/outputs.tf` | Terraform outputs (vm_id, talosconfig, kubeconfig) |
| `terraform/secrets.enc.json` | SOPS-encrypted Proxmox API token |
| `terraform/.tflint.hcl` | tflint linter configuration |
| `lefthook.yml` | Git hooks (pre-commit: fmt, validate, lint; commit-msg: conventional commits) |
| `.github/workflows/check.yml` | GitHub Actions CI — runs `mise run check` on PRs |
| `kubernetes/kustomization.yaml` | Root Kustomize entry point — scopes `flux-system` Kustomization CRD to `flux-system/` only |
| `kubernetes/flux-system/` | Auto-generated Flux controllers and sync config |
| `kubernetes/flux-system/infrastructure.yaml` | Flux Kustomization CRD — reconciles `kubernetes/infrastructure/` |
| `kubernetes/flux-system/infrastructure-config.yaml` | Flux Kustomization CRD — reconciles `kubernetes/infrastructure-config/` (depends on infrastructure) |
| `kubernetes/infrastructure-config/` | CRD-dependent resources (ClusterIssuer, Certificate, HTTPRoutes) — flat directory with prefixed filenames |
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
| `kubernetes/infrastructure/adguard/` | AdGuard Home DNS + Unbound recursive resolver |
| `kubernetes/infrastructure/monitoring/` | Observability stack — kube-prometheus-stack, Loki, Alloy, alerting |
| `kubernetes/infrastructure/cloudnative-pg/` | CloudNativePG operator (shared PostgreSQL infrastructure) |
| `kubernetes/infrastructure/postgres/` | PostgreSQL cluster instance via CloudNativePG |
| `kubernetes/infrastructure/authentik/` | Authentik identity provider, proxy outpost, forward-auth middleware |
| `kubernetes/cluster-policies/clusterpolicy-inject-forward-auth.yaml` | Kyverno policy: auto-inject forward-auth on all HTTPRoutes |
| `tests/kyverno/` | Kyverno CLI policy tests (forward-auth injection + skip) |
| `tests/e2e/` | Chainsaw E2E tests against live cluster (Flux health, DNS, TLS, auth) |
| `.kube-linter.yaml` | kube-linter configuration and exclusions |
| `.trivyignore` | Trivy false-positive exclusions |

## Providers

| Provider | Purpose |
|----------|---------|
| `bpg/proxmox` | Proxmox VM and image management |
| `siderolabs/talos` | TalosOS configuration and bootstrap |
| `carlpett/sops` | Inline decryption of encrypted secrets (inside `secrets` module) |

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
mise run check            # Full suite: tf fmt, validate, lint, tf test, kyverno test, kustomize, kubeconform, gitleaks
mise run security         # Security scanning: trivy, pluto, kube-linter
mise run e2e              # Chainsaw E2E tests against live cluster
mise run test:all         # check + security combined
mise run tf plan          # Verify Terraform changes before applying
flux check                # Verify Flux controllers are healthy
flux reconcile kustomization flux-system --with-source  # Force reconciliation
```

Three validation contexts: lefthook runs a fast subset on pre-commit (terraform fmt, kustomize build, gitleaks). `mise run check` runs the full suite on demand. GitHub Actions runs `mise run check` on every PR and gates merge.

Three test tiers: static (`mise run check` — terraform test, kyverno CLI, kubeconform, tflint, gitleaks), security (`mise run security` — trivy, pluto, kube-linter), and E2E (`mise run e2e` — chainsaw against live cluster).

## Implementation Notes

- **Talos 1.12 HostnameConfig**: Hostname uses the `HostnameConfig` multi-doc format (`apiVersion: v1alpha1, kind: HostnameConfig`) instead of the legacy `machine.network.hostname` field
- **VM IP bootstrapping**: `talos_machine_configuration_apply` connects to the VM's DHCP address (via QEMU guest agent `ipv4_addresses`), not the static IP being configured. Post-reboot resources (bootstrap, kubeconfig) use the static IP.
- **SOPS creation rules**: Files must match `\.enc\.(json|yaml)$` pattern. The `config:export` task writes directly to `.enc.yaml` filenames and uses `sops encrypt -i` (in-place)
- **Mise task args**: Use `usage` field with `var=#true` for optional arguments (not `arg()` template function)
- **Secrets module and `override_module`**: The SOPS provider lives inside `terraform/secrets/main.tf`, not the root module. Tests use `override_module { target = module.secrets }` to replace it with mock outputs, avoiding SOPS decryption during `terraform test`. This pattern keeps the real provider wiring out of test scope.
- **Flux Kustomization hierarchy**: Flux CRDs (`infrastructure.yaml`, `infrastructure-config.yaml`, `cluster-policies.yaml`, `apps.yaml`) live in `kubernetes/flux-system/` and are listed in its Kustomize `kustomization.yaml`. Target directories (`infrastructure/`, `infrastructure-config/`, `cluster-policies/`, `apps/`) have their own Kustomize `kustomization.yaml` with resource lists. The dependency chain is a diamond: `flux-system → infrastructure → infrastructure-config` and `infrastructure → cluster-policies → apps` — infrastructure-config and cluster-policies both depend on infrastructure and reconcile in parallel. infrastructure-config holds CRD-dependent resources (ClusterIssuer, Certificate, HTTPRoutes) that would deadlock the infrastructure Kustomization during server-side dry-run. Policies are separated from infrastructure because CRD-based resources (like Kyverno ClusterPolicy) cannot be applied in the same Kustomization as the HelmRelease that installs their CRDs — Flux's server-side dry-run rejects unknown kinds, deadlocking the reconciliation.
- **`mise run check` scope**: The `check` task runs from the project root (not `dir = "terraform"`). Terraform commands run in a subshell. Kubernetes validation is guarded by `[ -d kubernetes ]` and skips if the directory doesn't exist.
- **SOPS age key in cluster**: The `sops-age` Secret in `flux-system` provides the age private key to kustomize-controller for SOPS decryption. Created via `mise run flux:sops-key` — not managed by Terraform to keep the private key out of state. Re-run after cluster rebuild.
- **NFS provisioner pattern**: Infrastructure components follow a consistent directory structure under `kubernetes/infrastructure/`: dedicated namespace, HelmRepository, HelmRelease, and a Kustomize entry point. The parent `infrastructure/kustomization.yaml` references each component by directory name. This pattern repeats for ingress, cert-manager, and monitoring.
- **Kyverno image verification**: The ClusterPolicy verifies GHCR images (`ghcr.io/fluxcd/*`, `ghcr.io/kyverno/*`) in audit mode — unverified images are admitted but violations appear in PolicyReports (`kubectl get policyreport -A`). System namespaces (`kube-system`, `kyverno`) are excluded. Migrating to enforce mode requires reviewing audit results and potentially adding attestor entries for other signing authorities.
- **Gateway API CRDs**: CRDs fetched from upstream `kubernetes-sigs/gateway-api` via Flux GitRepository source, pinned to a commit SHA in `kubernetes/infrastructure/gateway-api/gitrepository.yaml`. Upgrade by changing the commit (look up the SHA for the desired release tag).
- **cert-manager DNS-01**: DigitalOcean DNS provider for Let's Encrypt challenges. The SOPS-encrypted API token (`secret.enc.yaml`) lives in the cert-manager directory. The ClusterIssuer is cluster-scoped; cert-manager looks for the token Secret in the cert-manager namespace.
- **Traefik Gateway API**: Gateway and GatewayClass created by the Helm chart (`gateway.enabled: true`). Default Gateway name is `traefik-gateway`. HTTPRoutes from any namespace can attach (`namespacePolicy.from: All`). Dashboard accessed via `kubectl port-forward deploy/traefik 8080:8080 -n traefik` (must target the Deployment, not the Service — chart v38 doesn't expose port 8080 on the Service or pass `api.insecure` to Traefik).
- **hostPort binding**: Traefik binds to node ports 80 and 443 via hostPort (mapped from container ports 8000 and 8443). No LoadBalancer or MetalLB needed. HTTP→HTTPS redirect at the entrypoint level, before Gateway routing. The traefik namespace requires `pod-security.kubernetes.io/enforce: privileged` because TalosOS enforces `baseline` PSA by default.
- **Wildcard certificate**: The Certificate resource targets the traefik namespace so the TLS Secret is co-located with the Gateway that references it (file: `infrastructure-config/traefik-certificate.yaml`). cert-manager renews automatically 30 days before expiry.
- **SOPS in kubernetes/**: The `mise run check` task strips `sops:` metadata from kustomize output before kubeconform validation (awk filter). Uses explicit `{print}` instead of bare pattern negation for macOS awk compatibility. Flux's kustomize-controller decrypts SOPS files at reconciliation time.
- **Flux CRD bootstrapping**: The infrastructure-config layer solves CRD ordering — CRD-dependent resources (ClusterIssuer, Certificate, HTTPRoutes) live in a separate Flux Kustomization that depends on infrastructure, so CRDs are installed before the dependent resources are dry-run checked. No manual intervention needed on fresh deploy. The `sops-age` Secret still requires `mise run flux:sops-key` after cluster rebuild.
- **infrastructure-config flat directory**: CRD-dependent resources from multiple infrastructure components are collected into `kubernetes/infrastructure-config/` with component-prefixed filenames (e.g., `cert-manager-clusterissuer.yaml`, `monitoring-httproute-grafana.yaml`). Only 7 resource files (plus kustomization.yaml) — subdirectories would be overkill. File contents are unchanged from their original locations; each already has the correct `namespace:` metadata.
- **Traefik chart v38 redirect syntax**: The `redirectTo` property was removed from the values schema. Use `redirections.entryPoint.to` instead (see `ports.web.redirections` in helmrelease.yaml).
- **Cross-namespace HTTPRoute**: Routes in app namespaces reference the Gateway with `parentRefs: [{name: traefik-gateway, namespace: traefik}]`. The Gateway permits this via `namespacePolicy.from: All`. Each app needs its own subdomain under `*.catinthehack.ca` — the wildcard cert covers all of them.
- **App deployment pattern**: The whoami app (`kubernetes/apps/whoami/`) is the template for future services: namespace, Deployment, Service, HTTPRoute, and a Kustomize entry point. Register each app directory in `kubernetes/apps/kustomization.yaml`.
- **Whoami hardened deployment**: Runs on port 8080 (non-privileged) with `readOnlyRootFilesystem`, `runAsNonRoot`, and dropped capabilities. Includes liveness and readiness probes. Future apps should follow this security baseline.
- **AdGuard Home DNS**: Network DNS server with ad-blocking and DNS rewrite (`*.catinthehack.ca -> 192.168.20.100`). Uses `hostNetwork: true` to bind port 53 on the node IP and `dnsPolicy: ClusterFirstWithHostNet` to route the pod's DNS through CoreDNS instead of the node's resolver. The `adguard` namespace requires `privileged` PSA, same as `traefik`.
- **Unbound recursive resolver**: AdGuard Home's sole upstream. Queries root nameservers directly; no third-party forwarders. ClusterIP service only — not exposed outside the cluster. DNSSEC validation enabled.
- **AdGuard Home config seeding**: The gabe565 Helm chart generates a ConfigMap from the `config` values key and copies it to the config PVC on first boot only; subsequent restarts preserve UI changes. Flux injects the admin password (bcrypt hash) via `valuesFrom` from a SOPS-encrypted Secret, deep-merged into chart values before Helm renders the config.
- **DNS circular dependency avoidance**: AdGuard Home runs on `hostNetwork` with `ClusterFirstWithHostNet` DNS policy. The pod resolves `unbound.adguard.svc.cluster.local` via CoreDNS, which forwards non-cluster queries to TalosOS Host DNS. TalosOS Host DNS uses `machine.network.nameservers` (static, set in Terraform) rather than DHCP-acquired DNS — this breaks the loop when router DHCP points at AdGuard Home. **Prerequisite:** `machine.network.nameservers` must be set to external resolvers (e.g., `1.1.1.1`, `8.8.8.8`) before changing router DHCP, or a node restart will deadlock.
- **Monitoring namespace PSA**: The `monitoring` namespace requires `pod-security.kubernetes.io/enforce: privileged` because prometheus-node-exporter uses `hostNetwork` and `hostPID` to collect host-level metrics. Same justification as `traefik` and `adguard` namespaces.
- **Observability namespace**: All monitoring components (Prometheus, Grafana, Alertmanager, Loki, Alloy) share the `monitoring` namespace in a single `kubernetes/infrastructure/monitoring/` directory. This deviates from the one-namespace-per-component pattern — these components form a tightly coupled system with shared HelmRepositories and cross-references.
- **Grafana datasource auto-discovery**: kube-prometheus-stack's Grafana sidecar watches for ConfigMaps labeled `grafana_datasource: "1"` in the monitoring namespace. Loki registers via this mechanism (`grafana-datasource-loki.yaml`).
- **Alertmanager Pushover credentials**: Mounted from the `monitoring-secrets` Secret via `alertmanager.alertmanagerSpec.secrets` in kube-prometheus-stack values. Credentials read from files at `/etc/alertmanager/secrets/monitoring-secrets/`. Edit with `mise run sops:edit kubernetes/infrastructure/monitoring/secret.enc.yaml`.
- **Alloy log collection**: Uses `loki.source.kubernetes` (Kubernetes API-based) not file-based tailing. No `/var/log` mount needed — correct for TalosOS's immutable filesystem. River config embedded in HelmRelease values via `alloy.configMap.content`.
- **Flux notification-controller**: Provider (type: alertmanager) and Alert resources in `flux-system/` push GitOps events to Alertmanager. Alert includes cross-namespace event sources for both `flux-system` and `monitoring`. Second signal path alongside Prometheus scraping Flux metrics via PodMonitor.
- **Flux metrics PodMonitor**: Lives in `monitoring` namespace, targets Flux controller pods in `flux-system` via `namespaceSelector`. Required for the FluxReconciliationFailure custom alert rule.
- **Loki storage**: Filesystem-backed TSDB in single-binary mode on NFS. Known risk: NFS's weaker fsync semantics. Fallback: switch to hostPath on local NVMe if corruption occurs.
- **Loki retention**: Requires both `limits_config.retention_period` and `compactor.retention_enabled: true`. Without the compactor flag, expired data is never deleted.
- **Exposed UIs without auth**: Grafana has built-in login. Prometheus, Alertmanager, and Alloy have no authentication — protected by the Authentik forward-auth gateway.
- **flux-system/kustomization.yaml manual additions**: Contains custom resources (infrastructure.yaml, infrastructure-config.yaml, apps.yaml, cluster-policies.yaml, provider-alertmanager.yaml, alert-flux.yaml) that must be re-added after `flux bootstrap` operations.
- **CloudNativePG operator**: Runs in `cnpg-system` namespace, installs Cluster, Backup, ScheduledBackup, Pooler, and Database CRDs. Manages PostgreSQL instances across all namespaces.
- **Shared PostgreSQL**: CloudNativePG cluster in `postgres` namespace. Single instance on NFS. Same fsync risk as Loki — fallback to hostPath on local NVMe if corruption occurs. Services: `postgres-cluster-rw.postgres.svc` (read-write), `postgres-cluster-ro.postgres.svc` (read-only). Future services (Gitea, Infisical) add databases via the `Database` CRD or by updating the cluster chart values with additional `roles` entries.
- **Authentik existingSecret**: All credentials stored in a single SOPS-encrypted Secret (`authentik-secrets`). The chart reads `AUTHENTIK_*` environment variables from this Secret via `existingSecret.secretName`. No inline values in HelmRelease.
- **Authentik blueprints**: Mounted via `blueprints.configMaps` in HelmRelease values. Chart mounts at `/blueprints/mounted/cm-{name}/`, not `/blueprints/custom/`. Only the worker pod processes blueprints. Files numbered (`01-`, `02-`) for processing order.
- **Authentik removed Redis**: As of v2025.10, PostgreSQL handles caching, sessions, and task queuing. No Redis configuration exists in the chart or application. Redis deployment deferred until a future service requires it.
- **Proxy outpost**: Manual Deployment using `ghcr.io/goauthentik/proxy:{version}`. Pin image tag to match Authentik server version. Connects to Authentik via `AUTHENTIK_HOST` (external URL) with `AUTHENTIK_INSECURE=true` for in-cluster hairpin routing. `AUTHENTIK_TOKEN` must match `AUTHENTIK_BOOTSTRAP_TOKEN`.
- **Kyverno forward-auth mutation**: ClusterPolicy `inject-authentik-forward-auth` adds `traefik.io/middleware` annotation to all HTTPRoutes via mutating admission webhook. Fires before SSA processing — no conflict with Flux reconciliation. Opt out with label `auth.catinthehack.ca/skip: "true"`.
- **Bitnami Helm charts frozen**: Docker Hub OCI registry (`oci://registry-1.docker.io/bitnamicharts`) stopped receiving updates August 2025. Container images also frozen. Use alternative charts (CloudNativePG for PostgreSQL) or pin to last available versions with image overrides.

## Deployment Lessons

Patterns learned from building this project that apply to all future work.

### Git workflow
- **Main is protected.** All changes require a PR with passing CI. Never commit directly to main.
- **Merge, never rebase** when a feature branch falls behind main. Rebase rewrites history and requires force push. `git merge origin/main --no-edit` keeps a clean push.
- **Commit design docs on the feature branch**, not main. Committing to main before branching causes divergence that must be resolved after the PR merges.
- **Use `gh pr checks <number> --watch` to wait for CI.** Don't poll manually with `sleep` — `--watch` blocks until all checks complete and exits with the correct status code.

### SOPS secrets
- **Create secrets with placeholder values**, encrypt them, and commit. Document what the user must fill in and how (`mise run sops:edit <path>`). This lets CI validate the resource structure while real credentials arrive later.
- **Collect credentials before starting implementation.** Asking mid-flow interrupts momentum. List prerequisites (accounts to create, keys to generate) in the plan and resolve them first.

### Infrastructure-as-code
- **Pin exact Helm chart versions at implementation time.** Plans should specify major version ranges (e.g., `82.x`). The implementing agent looks up the latest patch version when writing the HelmRelease.
- **Tightly coupled components belong in one directory.** The observability stack shares a namespace, HelmRepositories, and cross-references. Splitting into separate directories creates hidden dependencies. One directory with prefixed filenames (`helmrelease-loki.yaml`, `helmrelease-alloy.yaml`) keeps everything self-contained.
- **Review Helm chart values against upstream docs before implementation.** A four-agent review caught 21 issues — duplicate YAML keys, wrong nesting paths, missing required flags. These would have silently broken deployment with no validation error.
- **Check the chart's dependency tree for library version.** The gabe565/adguard-home chart pins bjw-s common library v1.5.1, where `hostNetwork` and `dnsPolicy` are root-level values fields. The v2.x library moved them under `defaultPodOptions`. Wrong nesting silently produces a pod without host networking — no error, just broken DNS.
- **Add Helm to tooling early and run `helm show values`.** Download the actual chart before writing HelmReleases. Default values reveal field names, nesting depth, and type expectations. The AdGuard Home chart accepts `config` as either a YAML string or structured map — only visible by reading the template source.
- **Cross-reference resource names against existing cluster config.** StorageClass `nfs` vs `nfs-client` was caught only by comparing against the nfs-provisioner HelmRelease. Always verify names of cluster-scoped resources (StorageClasses, ClusterIssuers, Gateways) against what is already deployed.

### Network architecture
- **hostNetwork pods need `dnsPolicy: ClusterFirstWithHostNet`.** Without it, a pod using the host network stack resolves DNS through the node's `/etc/resolv.conf` and cannot reach cluster services like `unbound.adguard.svc.cluster.local`.
- **Prevent DNS circular dependencies at the node level.** When the cluster hosts the network's DNS server, nodes must have static nameservers independent of DHCP. Otherwise a node restart deadlocks: kubelet needs DNS to pull images, but the DNS pod cannot start without the images. Set `machine.network.nameservers` in TalosOS to external resolvers (e.g., `9.9.9.10`).

### App deployment pattern
- **Use `valuesFrom` with SOPS-encrypted Secrets for credentials.** Flux deep-merges Secret values into HelmRelease values before Helm renders templates. Store only the sensitive subset (e.g., bcrypt password hash) in the Secret; keep all other config in the HelmRelease values block.

### Identity and auth
- **Verify upstream project changes before planning.** Authentik removed Redis in v2025.10 — the design assumed Redis was still required. Always check release notes for the target version. Stale assumptions create unnecessary infrastructure.
- **Prefer `existingSecret` over inline credentials.** Authentik's `existingSecret.secretName` loads all `AUTHENTIK_*` environment variables from one Secret. Simpler than `valuesFrom` deep-merge when the chart supports it natively.
- **Use `forward_domain` mode, not `forward_single`.** `forward_domain` shares a single auth cookie across all subdomains (`cookie_domain: catinthehack.ca`). `forward_single` requires a separate provider per subdomain.
- **Separate operator from instance.** CloudNativePG operator (`cnpg-system`) installs CRDs; the PostgreSQL cluster (`postgres`) is a separate HelmRelease with `dependsOn`. This pattern avoids CRD race conditions and allows multiple clusters from one operator.
- **Place CRD-dependent middleware in `cluster-policies/`.** The Traefik ForwardAuth Middleware uses `traefik.io/v1alpha1` — a CRD installed by Traefik's HelmRelease. Placing the Middleware in `infrastructure/` deadlocks Flux's server-side dry-run. The `cluster-policies` layer depends on `infrastructure`, so CRDs exist before the Middleware is applied.
- **Blueprint cross-file references use `!Find`, not `!KeyOf`.** Within a single blueprint file, `!KeyOf` resolves by local `id` field. Across files (e.g., blueprint 03 referencing a flow from 01), `!Find` performs a database lookup by identifier. Wrong reference type silently fails.
- **Bitnami charts are frozen — plan alternatives.** Docker Hub OCI registry stopped publishing Bitnami charts and images in August 2025. CloudNativePG replaces Bitnami PostgreSQL. Future services needing Redis should evaluate alternatives (Dragonfly, KeyDB, or upstream Redis charts).
