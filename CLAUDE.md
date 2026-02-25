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
mise run dns:set          # Point local DNS at AdGuard Home (192.168.20.100)
mise run dns:unset        # Revert local DNS to DHCP defaults
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
| `kubernetes/infrastructure/forgejo/` | Forgejo server, Actions runner, and push mirror to GitHub |
| `kubernetes/apps/renovate/` | Renovate automated dependency updater (CronJob) |
| `kubernetes/apps/headlamp/` | Headlamp Kubernetes dashboard (cluster-admin, Authentik OIDC) |
| `.forgejo/workflows/check.yml` | Forgejo Actions CI — runs `mise run check` on PRs (mirrors `.github/workflows/check.yml`) |
| `renovate.json` | Renovate in-repo config — Flux manager file patterns, package grouping rules |
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
- **AdGuard Home config seeding**: The gabe565 Helm chart embeds the full AdGuard config as an inline YAML string under the `config` values key in the HelmRelease. Set `schema_version: 29` to match the running AdGuard version — this skips all config migrations and avoids the v3 migration bug that double-wraps `bootstrap_dns` arrays. In schema v29, DNS rewrites live under `filtering:` not `dns:`. The chart's init container copies the rendered ConfigMap to the config PVC on first boot only; subsequent restarts preserve UI changes. Delete the PVC to re-seed after config changes. Bind DNS to `192.168.20.100` (not `0.0.0.0`) to avoid port 53 conflicts with CoreDNS.
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
- **Authentik blueprints**: Four blueprints in a single ConfigMap, mounted via `blueprints.configMaps` in HelmRelease values. Chart mounts at `/blueprints/mounted/cm-{name}/`, not `/blueprints/custom/`. Only the worker pod processes blueprints. `01-forward-auth-provider.yaml` creates the proxy provider (forward_domain mode) and application. `02-proxy-outpost.yaml` creates the outpost with Kubernetes service connection. `03-forgejo-oidc.yaml` and `04-headlamp-oidc-provider.yaml` create OAuth2 providers and applications for OIDC SSO, reading credentials via `!Env`. Blueprints in the same ConfigMap may process in parallel; cross-file `!Find` references can fail on first apply if the referenced resource hasn't committed to the database yet. A worker restart resolves this.
- **Authentik removed Redis**: As of v2025.10, PostgreSQL handles caching, sessions, and task queuing. No Redis configuration exists in the chart or application. Redis deployment deferred until a future service requires it.
- **Authentik managed outpost**: Authentik's Kubernetes integration auto-deploys the proxy outpost (Deployment, Service, Secret) via the `service_connection` field in the outpost blueprint pointing to `Local Kubernetes Cluster`. Managed outposts use `ak-outpost-{name}` naming (e.g., `ak-outpost-traefik-outpost`). Connects to Authentik server via in-cluster service name (`http://authentik-server.authentik.svc:80`) configured in the outpost blueprint's `authentik_host`. Set `authentik_host_browser: https://auth.catinthehack.ca` so browser-facing redirects use the external URL while pod-to-pod communication stays internal. Without this, the outpost redirects browsers to the unresolvable in-cluster service name. The outpost HTTPRoute remains manually managed because Authentik's `kubernetes_httproute_annotations` setting cannot set labels — the Kyverno forward-auth skip requires label `auth.catinthehack.ca/skip: "true"`, not an annotation.
- **Outpost session storage**: The managed outpost uses a filesystem session backend with no PVC — sessions are ephemeral. Restarting the outpost pod destroys all active sessions. Users mid-auth-flow when the pod restarts will see a 400 "mismatched session ID" error because the callback carries a state JWT referencing a session that no longer exists. The fix is to retry from scratch (clear cookies or use incognito). After any outpost restart, expect in-flight auth flows to fail.
- **Kyverno forward-auth injection**: ClusterPolicy `inject-authentik-forward-auth` has two rules. The `generate` rule creates a ForwardAuth Middleware in each app namespace (`generateExisting: true`, `synchronize: true`). The `mutate` rule injects an `ExtensionRef` filter into every HTTPRoute rule pointing to that Middleware. The `traefik.io/middleware` annotation does NOT work with Gateway API — only `ExtensionRef` filters do. Kyverno requires RBAC for `traefik.io/v1alpha1/Middleware` (admission-controller: get/list; background-controller: full CRUD), configured via `rbac.clusterRole.extraResources` in the Kyverno HelmRelease. Opt out with label `auth.catinthehack.ca/skip: "true"`.
- **Bitnami Helm charts frozen**: Docker Hub OCI registry (`oci://registry-1.docker.io/bitnamicharts`) stopped receiving updates August 2025. Container images also frozen. Use alternative charts (CloudNativePG for PostgreSQL) or pin to last available versions with image overrides.
- **Forgejo Helm chart OCI migration**: The Forgejo Helm chart migrated from Codeberg (`https://codeberg.org/forgejo-helm/pages/`) to `oci://code.forgejo.org/forgejo-helm` in January 2026. The old URL returns 404. Use `type: oci` in the HelmRepository.
- **Forgejo multi-secret pattern**: Forgejo uses separate SOPS-encrypted Secrets per concern: `secret-admin.enc.yaml` (admin credentials, `valuesFrom`), `secret-db.enc.yaml` (database password, `additionalConfigSources`), `secret-oauth.enc.yaml` (OIDC client secret), `secret-runner.enc.yaml` (runner registration token). This differs from the Authentik single-secret pattern.
- **Forgejo database via psql**: The Forgejo database and role are created manually via `kubectl exec` into the CloudNativePG pod, not via the Database CRD (which lacks role creation). Re-run after cluster rebuild.
- **Forgejo Actions DEFAULT_ACTIONS_URL**: Set to `https://github.com` so workflow `uses:` references (e.g., `actions/checkout@v4`) resolve directly to GitHub without the `https://github.com/` prefix. Without this, Forgejo prepends its own URL.
- **Forgejo runner DinD mitigations**: The runner pod runs privileged (same PSA as traefik, adguard). Blast radius is limited by `valid_volumes: []` (no host mounts from CI jobs) and `container.options: "--memory=1g --cpus=2"` (resource limits on DinD containers). Runner itself is unprivileged (`privileged: false`); only the DinD sidecar needs privilege.
- **Forgejo runner registration**: The forgejo-runner Helm chart's pre-install hook creates a secret named `{release}-config` (e.g., `forgejo-runner-config`) to store the registered runner's `.runner` file. When using `existingInitSecret`, the Flux-managed SOPS secret **must have a different name** (e.g., `forgejo-runner-init`) to avoid colliding with the hook-created secret. The hook reads `CONFIG_INSTANCE`, `CONFIG_NAME`, and `CONFIG_TOKEN` from the init secret, registers with Forgejo, and patches the `.runner` data into the release-named secret. Generate the registration token via `GET /api/v1/admin/runners/registration-token`.
- **Forgejo HTTPRoute skip-auth**: The Forgejo HTTPRoute uses label `auth.catinthehack.ca/skip: "true"` to bypass Kyverno forward-auth injection. Forgejo handles its own authentication (built-in + OIDC). API clients (Renovate, Flux) connect via in-cluster service name and would break if challenged by forward-auth.
- **Renovate Flux managerFilePatterns**: Renovate's built-in Flux manager only matches `gotk-components.yaml` by default. The `managerFilePatterns` override in `renovate.json` (`/kubernetes/.+\\.ya?ml$/`) is required for Renovate to detect HelmRelease version updates across all Kubernetes YAML files.
- **Renovate in-cluster endpoint**: Renovate connects to Forgejo via `http://forgejo-http.forgejo.svc:3000` to bypass the Authentik forward-auth gateway. External URL access would trigger auth challenges on API calls.
- **Forgejo OIDC via Authentik blueprint**: The OAuth2 provider and application for Forgejo SSO are created by blueprint `03-forgejo-oidc.yaml` in the `authentik-blueprints` ConfigMap. Client credentials are read via `!Env FORGEJO_OIDC_CLIENT_ID` and `!Env FORGEJO_OIDC_CLIENT_SECRET` from the `authentik-secrets` Secret. The same values must also be set in Forgejo's `secret-oauth.enc.yaml` (`key` and `secret` fields). Duplication is unavoidable — Kubernetes secrets are namespace-scoped.
- **Forgejo OIDC split-URL pattern**: The `autoDiscoverUrl` uses the in-cluster URL (`http://authentik-server.authentik.svc:80/...`) because pods can't resolve `*.catinthehack.ca` via CoreDNS. The `customAuthUrl` overrides the authorization endpoint with the external URL (`https://auth.catinthehack.ca/...`) for browser redirects. Token exchange and JWKS verification use the discovered in-cluster endpoints (server-side).
- **Flux source HTTPS with token auth**: After cutover, Flux reconciles from Forgejo via `https://git.catinthehack.ca` with a PAT. The `flux bootstrap gitea` command uses `--token-auth` (no SSH deploy key). The PAT is stored in the `flux-system` namespace Secret created by bootstrap.

- **Local DNS tasks**: `dns:set` and `dns:unset` configure macOS DNS on Ethernet, USB LAN, and Wi-Fi interfaces. Requires AdGuard Home running at `192.168.20.100`. Use `dns:unset` to revert to DHCP if DNS breaks. Both tasks print verification output after applying changes.
- **Pushover notification templates**: HelmRelease values are data, not Helm templates. Use direct Go template syntax (`{{ .CommonLabels.alertname }}`) in Alertmanager receiver configs — do NOT escape with `{{ "{{" }}`. Named templates defined in `alertmanager.templateFiles` keep the receiver config clean.
- **Grafana dashboard provisioning**: Dashboards defined as JSON inside ConfigMaps labeled `grafana_dashboard: "1"`. Grafana's sidecar auto-discovers them in the monitoring namespace. Same mechanism as datasource auto-discovery.
- **Headlamp OIDC auth**: Headlamp supports native OIDC via `config.oidc` in the Helm values. Configured to authenticate against Authentik (`issuerURL: https://auth.catinthehack.ca/application/o/headlamp/`). OIDC credentials stored in a SOPS-encrypted Secret, injected via `valuesFrom`. Kyverno forward-auth still applies to the HTTPRoute, but the OIDC login replaces the manual ServiceAccount token flow.
- **Headlamp cluster-admin RBAC**: Uses `cluster-admin` ClusterRole via `clusterRoleBinding.clusterRoleName: cluster-admin`. Full visibility into all resources including CRDs. The Helm chart deduplicates the ServiceAccount name when release name matches chart name — SA is `headlamp`, not `headlamp-headlamp`.
- **TalosOS writable partition**: TalosOS uses a read-only squashfs root (`/`). The writable partition is `/var`. Node-exporter excludes squashfs and overlay filesystems, so `mountpoint="/"` produces no data. Use `mountpoint="/var"` for disk space alerts and dashboard panels.
- **Grafana datasource UIDs**: Auto-generated UIDs are not deterministic and don't match human-readable names. Always set `uid` explicitly in datasource provisioning ConfigMaps (e.g., `uid: loki`). Dashboard JSON references datasources by `{"uid": "loki"}` — without the explicit UID, panels show "datasource not found".
- **Authentik OIDC blueprint pattern**: For services that support native OIDC, create a blueprint entry with `authentik_providers_oauth2.oauth2provider` model. Store the client ID and secret in the `authentik-secrets` SOPS Secret, expose them via `global.env` `secretKeyRef`, and reference them in the blueprint via `!Env KEY_NAME` (scalar syntax, no brackets). This keeps the ConfigMap free of secrets while the public repo remains safe. The same credentials go into the service's own SOPS Secret for injection via Flux `valuesFrom`.
- **`!Env` is a scalar tag, not a sequence.** Use `!Env VAR_NAME` or `!Env VAR_NAME, default_value`. Do NOT use `!Env [VAR_NAME]` — the sequence form expects exactly 2 elements and throws `IndexError` with only 1. This differs from `!Find` which uses sequence syntax.
- **Authentik scope mappings model name**: OAuth2 scope mappings use `authentik_providers_oauth2.scopemapping` (not `authentik_providers_oauth2.oauth2scopemapping`). Reference built-in scopes via `!Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]`.
- **Authentik v2025.x `redirect_uris` format**: CVE-2024-52289 changed `redirect_uris` from strings to structured objects. Use `- matching_mode: strict` and `url: https://...` instead of bare strings. The serializer rejects strings with "Expected a dictionary, but got str." Blueprint validation fails silently (status: `error`, no exception logged) — use the Importer directly to see validation errors.
- **Forgejo reserved admin username**: Forgejo reserves `admin` as a username. The Helm chart's `configure-gitea` init container crashes with `name is reserved [name: admin]`. Use a different username like `forgejo_admin` in the admin Secret.

## Deployment Lessons

Patterns learned from building this project that apply to all future work.

### Git workflow
- **Main is protected.** All changes require a PR with passing CI. Never commit directly to main.
- **Merge, never rebase** when a feature branch falls behind main. Rebase rewrites history and requires force push. `git merge origin/main --no-edit` keeps a clean push.
- **Commit design docs on the feature branch**, not main. Committing to main before branching causes divergence that must be resolved after the PR merges.
- **Use `gh pr checks <number> --watch` to wait for CI.** Don't poll manually with `sleep` — `--watch` blocks until all checks complete and exits with the correct status code.
- **GitHub auto-deletes remote branches on merge.** After `gh pr merge`, only the local branch needs cleanup (`git branch -d`). Don't attempt `git push origin --delete` — the remote ref no longer exists.

### SOPS secrets
- **Create secrets with placeholder values**, encrypt them, and commit. Document what the user must fill in and how (`mise run sops:edit <path>`). This lets CI validate the resource structure while real credentials arrive later.
- **Collect credentials before starting implementation.** Asking mid-flow interrupts momentum. List prerequisites (accounts to create, keys to generate) in the plan and resolve them first.
- **Use `sops set` to add keys without decrypting.** `sops set <file> '["stringData"]["KEY"]' '"value"'` modifies individual keys in an encrypted file without exposing other values to stdout. Safer than decrypt-edit-encrypt for automation and CI contexts. Use this when adding new keys to an existing Secret.
- **Recreate SOPS files with placeholder-only content.** When a Secret contains only placeholder values (no real secrets yet), overwrite it with the real plaintext YAML and run `sops encrypt -i`. Simpler than `sops set` for each key, and no decryption occurs.
- **Symlink `.age-key.txt` into worktrees.** The age key file is gitignored and absent from new worktrees. SOPS operations fail without it. Create a symlink to the main repo's key (`ln -s /path/to/main/.age-key.txt .age-key.txt`), run SOPS commands, then remove the symlink. Automate this in worktree setup scripts.

### Infrastructure-as-code
- **Pin exact Helm chart versions at implementation time.** Plans should specify major version ranges (e.g., `82.x`). The implementing agent looks up the latest patch version when writing the HelmRelease.
- **Tightly coupled components belong in one directory.** The observability stack shares a namespace, HelmRepositories, and cross-references. Splitting into separate directories creates hidden dependencies. One directory with prefixed filenames (`helmrelease-loki.yaml`, `helmrelease-alloy.yaml`) keeps everything self-contained.
- **Review Helm chart values against upstream docs before implementation.** A four-agent review caught 21 issues — duplicate YAML keys, wrong nesting paths, missing required flags. These would have silently broken deployment with no validation error.
- **Check the chart's dependency tree for library version.** The gabe565/adguard-home chart pins bjw-s common library v1.5.1, where `hostNetwork` and `dnsPolicy` are root-level values fields. The v2.x library moved them under `defaultPodOptions`. Wrong nesting silently produces a pod without host networking — no error, just broken DNS.
- **Add Helm to tooling early and run `helm show values`.** Download the actual chart before writing HelmReleases. Default values reveal field names, nesting depth, and type expectations. The AdGuard Home chart accepts `config` as either a YAML string or structured map — only visible by reading the template source.
- **Cross-reference resource names against existing cluster config.** StorageClass `nfs` vs `nfs-client` was caught only by comparing against the nfs-provisioner HelmRelease. Always verify names of cluster-scoped resources (StorageClasses, ClusterIssuers, Gateways) against what is already deployed.
- **Set `schema_version` to match the running application version.** AdGuard Home's v3 config migration double-wraps `bootstrap_dns` arrays. Setting `schema_version: 29` in the seed config skips all migrations and avoids the bug. Check migration code when seeding config for any app that runs automatic migrations.

### Helm and Flux operations
- **Inspect Helm hook behavior with `helm template --show-only`.** Pre-install hooks can create secrets, jobs, and RBAC resources that collide with Flux-managed resources. Render the chart locally (`helm template <release> <chart> --show-only templates/jobs.yaml`) to see exactly what hooks create before writing HelmReleases.
- **Recover stalled HelmReleases with `flux reconcile --reset`.** After a HelmRelease exhausts its retry count (`RetriesExceeded`), Flux stops retrying. `flux reconcile helmrelease <name> --reset` resets the failure counters. Use `--force` to trigger a one-off install or upgrade. Without `--reset`, the controller ignores the stalled release.
- **Helm hook secrets collide with Flux-managed secrets.** Charts that create secrets in pre-install hooks use predictable names (`{release}-config`). If Flux also manages a secret with the same name (via Kustomization), the hook fails with "already exists." Name the Flux-managed secret differently and reference it via chart values (e.g., `existingInitSecret`).
- **Clean up orphaned Helm resources after failed installs.** A failed Helm install can leave behind hook-created secrets, jobs, and RBAC resources. Subsequent install attempts fail because these resources already exist. Delete them manually (`kubectl delete secret <name>`) before retrying. `helm uninstall` may also be needed to clear the release record.

### Network architecture
- **hostNetwork pods need `dnsPolicy: ClusterFirstWithHostNet`.** Without it, a pod using the host network stack resolves DNS through the node's `/etc/resolv.conf` and cannot reach cluster services like `unbound.adguard.svc.cluster.local`.
- **Prevent DNS circular dependencies at the node level.** When the cluster hosts the network's DNS server, nodes must have static nameservers independent of DHCP. Otherwise a node restart deadlocks: kubelet needs DNS to pull images, but the DNS pod cannot start without the images. Set `machine.network.nameservers` in TalosOS to external resolvers (e.g., `9.9.9.10`).
- **CoreDNS cannot resolve external wildcard domains.** `*.catinthehack.ca` resolves only through AdGuard Home's DNS rewrites. In-cluster services that reach other in-cluster services by external hostname fail if their DNS path doesn't include AdGuard. Use in-cluster service names instead.
- **Use in-cluster service names for pod-to-pod communication.** External URLs (e.g., `https://auth.catinthehack.ca`) require wildcard DNS resolution, hairpin routing, and TLS termination. In-cluster names (e.g., `http://authentik-server.authentik.svc:80`) bypass all three. Prefer in-cluster names whenever the client and server share the same cluster.

### SOPS discipline
- **Only encrypt actual secrets.** Values like `AUTHENTIK_HOST` and `AUTHENTIK_INSECURE` are configuration, not credentials. Placing them in SOPS-encrypted Secrets adds operational complexity (editing, diffing) for no security benefit. Keep non-secret env vars as plain values.

### App deployment pattern
- **Use `valuesFrom` with SOPS-encrypted Secrets for credentials.** Flux deep-merges Secret values into HelmRelease values before Helm renders templates. Store only the sensitive subset (e.g., bcrypt password hash) in the Secret; keep all other config in the HelmRelease values block.

### Identity and auth
- **Verify upstream project changes before planning.** Authentik removed Redis in v2025.10 — the design assumed Redis was still required. Always check release notes for the target version. Stale assumptions create unnecessary infrastructure.
- **Prefer `existingSecret` over inline credentials.** Authentik's `existingSecret.secretName` loads all `AUTHENTIK_*` environment variables from one Secret. Simpler than `valuesFrom` deep-merge when the chart supports it natively.
- **Use `forward_domain` mode, not `forward_single`.** `forward_domain` shares a single auth cookie across all subdomains (`cookie_domain: catinthehack.ca`). `forward_single` requires a separate provider per subdomain.
- **Separate operator from instance.** CloudNativePG operator (`cnpg-system`) installs CRDs; the PostgreSQL cluster (`postgres`) is a separate HelmRelease with `dependsOn`. This pattern avoids CRD race conditions and allows multiple clusters from one operator.
- **Place CRD-dependent middleware in `cluster-policies/`.** The Traefik ForwardAuth Middleware uses `traefik.io/v1alpha1` — a CRD installed by Traefik's HelmRelease. Placing the Middleware in `infrastructure/` deadlocks Flux's server-side dry-run. The `cluster-policies` layer depends on `infrastructure`, so CRDs exist before the Middleware is applied.
- **Blueprint cross-file references use `!Find`, not `!KeyOf`.** Within a single blueprint file, `!KeyOf` resolves by local `id` field. Across files (e.g., blueprint 03 referencing a flow from 01), `!Find` performs a database lookup by identifier. Wrong reference type silently fails.
- **Blueprint parallel processing causes `!Find` race conditions.** Blueprints in the same ConfigMap may process simultaneously. A `!Find` for a resource created by another blueprint can fail if that resource hasn't committed to the database yet. Restart the worker — the second attempt succeeds because the referenced resource now exists.
- **Debug silent blueprint failures with the Importer.** Blueprint `apply_blueprint` tasks finish with `exc: null` even when validation fails — the error is swallowed. To see the actual error, exec into the worker pod and run `Importer.from_string(content).validate()` directly. This returns `(False, [log_entries])` with the exact serializer error.
- **Authentik proxy provider v2025.x requires `invalidation_flow`.** Mandatory since v2024.10. The field silently accepts null from a failed `!Find`, then errors at runtime. Verify flow slugs match built-in names exactly (e.g., `default-authentication-flow`, not `default-authentication`).
- **Prefer built-in flows over custom blueprints.** Authentik ships `default-authentication-flow` and `default-invalidation-flow`. Creating custom flows for standard authentication adds maintenance burden. Reference built-ins via `!Find [authentik_flows.flow, [slug, <slug>]]`.
- **Let Authentik manage the outpost.** Manual outpost Deployments require coordinating image versions, API tokens, and service names. Authentik's Kubernetes integration auto-deploys the outpost with the correct token via a blueprint `service_connection` to `Local Kubernetes Cluster`. Eliminates token mismatch errors and manual image pinning.
- **Gateway API uses `ExtensionRef` filters, not annotations, for middleware.** The `traefik.io/middleware` annotation is silently ignored by Traefik's Gateway API provider. Use `ExtensionRef` filters in HTTPRoute rules instead. The Middleware must be in the same namespace as the HTTPRoute — cross-namespace references are not supported. Kyverno `generate` rules can auto-create Middlewares per namespace.
- **Kyverno `generate` rules need RBAC for the target resource type.** The admission-controller needs `get`/`list` to validate the policy. The background-controller needs full CRUD to create and synchronize generated resources. Configure via `rbac.clusterRole.extraResources` in the Kyverno Helm chart values.
- **Bitnami charts are frozen — plan alternatives.** Docker Hub OCI registry stopped publishing Bitnami charts and images in August 2025. CloudNativePG replaces Bitnami PostgreSQL. Future services needing Redis should evaluate alternatives (Dragonfly, KeyDB, or upstream Redis charts).

### Forgejo and Renovate
- **Check Helm chart registry migrations before implementing.** The Forgejo Helm chart moved from Codeberg to `oci://code.forgejo.org/forgejo-helm` in January 2026. The plan's URL returned 404. Always run `helm show chart` against the planned registry URL before writing the HelmRepository.
- **Use separate secrets per concern, not one monolith.** Forgejo's `valuesFrom` deep-merge and `additionalConfigSources` reference different Secrets. Splitting admin, database, OAuth, and runner credentials into separate files makes editing and rotating individual credentials easier.
- **Create databases manually when the CRD lacks role support.** CloudNativePG's Database CRD creates databases but cannot create roles. Use `kubectl exec` into the primary pod and run `CREATE ROLE ... CREATE DATABASE ... GRANT` manually. Document the commands for cluster rebuild.
- **Limit DinD blast radius with runner config, not pod security.** The runner pod must be privileged for DinD. Restrict CI job capabilities via runner config: `valid_volumes: []` prevents host mount escapes, `container.options` caps CPU and memory. These are defense-in-depth controls, not substitutes for pod isolation.
- **Override Renovate's Flux managerFilePatterns.** The built-in Flux manager only matches `gotk-components.yaml`. Without `managerFilePatterns` covering all Kubernetes YAML files, Renovate silently ignores every HelmRelease version field.
- **Use in-cluster service names for machine-to-machine API calls.** Renovate and the runner connect to Forgejo via `forgejo-http.forgejo.svc:3000`, bypassing forward-auth. External URLs would trigger authentication challenges on API calls. Same pattern as Authentik's in-cluster `authentik_host`.
- **Suspend flux-system before bootstrap to a new source.** `flux bootstrap gitea` overwrites `kubernetes/flux-system/kustomization.yaml`. If `prune: true` is set, Flux would delete all resources not in the new kustomization. Suspend first, bootstrap, re-add custom entries, then resume.
- **Split OIDC discovery and auth URLs when pods can't resolve external domains.** Pods resolve DNS via CoreDNS, which forwards non-cluster queries to external resolvers that don't have AdGuard's DNS rewrites. Use the in-cluster URL for `autoDiscoverUrl` (server-side discovery, token exchange, JWKS) and override `customAuthUrl` with the external URL (browser redirect). This is the same split-URL pattern as Authentik's `authentik_host` / `authentik_host_browser`.
- **Automate Authentik provider creation via blueprints, not UI clicks.** OIDC providers, applications, and outposts are reproducible via blueprint YAML in a ConfigMap. Use `!Env` to inject secrets from the existing `authentik-secrets` Secret. Eliminates manual UI configuration and survives cluster rebuilds.

- **Set `authentik_host_browser` when `authentik_host` is internal.** The outpost uses `authentik_host` for API communication and browser redirects. When `authentik_host` points to an in-cluster service name, the browser receives an unresolvable URL. Set `authentik_host_browser` to the external URL (`https://auth.catinthehack.ca`) in the outpost blueprint's `config` block. Both fields are required whenever internal and external URLs differ.
- **Outpost pod restarts invalidate in-flight auth flows.** The proxy outpost stores OAuth state in ephemeral filesystem sessions. Restarting the pod wipes all sessions — any user mid-login receives a 400 "mismatched session ID" error because the callback's state JWT references a destroyed session. After outpost restarts, tell affected users to retry from scratch (clear cookies or incognito). Restart the outpost pod after blueprint changes: `kubectl rollout restart deploy/ak-outpost-traefik-outpost -n authentik`.
- **Use `!Env` for secrets in blueprints, not inline values.** Blueprint ConfigMaps are plaintext and committed to a public repo. Inject credentials through pod environment variables (`global.env` with `secretKeyRef`) and reference them via `!Env VAR_NAME` (scalar syntax) in the blueprint. Every `!Env` reference requires a matching `global.env` entry in the Authentik HelmRelease — `!Env` reads pod environment variables, not Kubernetes Secret values directly. Missing env vars cause silent blueprint failures (status: `error`, no exception).
- **Reuse `authentik-secrets` for non-Authentik credentials when the worker needs them.** The `global.env` mechanism exposes any Secret key as an environment variable in the worker pod. Adding Headlamp OIDC credentials to `authentik-secrets` avoids creating a cross-namespace Secret reference. The worker reads them via `!Env`; the target service reads them from its own namespace-local Secret.

### Worktree and tooling
- **Symlink shared secrets into worktrees.** Git worktrees don't share gitignored files (`.age-key.txt`, decrypted kubeconfig). Symlink them from the main repo: `ln -s /path/to/main/.age-key.txt .age-key.txt`. Without the age key, `sops` and `mise run config:decrypt` fail silently or with unhelpful errors.
- **Use `sops --set` for non-interactive secret edits.** Instead of `sops:edit` (which opens `$EDITOR`), use `sops --set '["stringData"]["field"] "value"' file.enc.yaml` for programmatic updates. Useful in scripts, CI, and agent-driven workflows. Verify with `sops decrypt file.enc.yaml | grep field`.
- **Run `mise trust` and `mise run tf init` in new worktrees.** Worktrees start with untrusted config and no `.terraform/` directory. Both commands must run before `mise run check` passes. `tflint --init` may also be needed if plugins aren't cached globally.
- **Helm chart registries migrate — always verify URLs.** The Forgejo Helm chart moved from `https://codeberg.org/forgejo-helm/pages/` to `oci://code.forgejo.org/forgejo-helm` in January 2026. The plan's URL returned 404. Run `helm show chart <url>` before writing HelmRepository resources to catch stale URLs early.
- **Cross-namespace credential sharing requires duplication.** Kubernetes Secrets are namespace-scoped. When two components in different namespaces need the same credential (e.g., OIDC client secret shared between Authentik and Forgejo), the value must exist in both Secrets. Generate once, write to both via `sops --set`. Document the pairing so future rotations update both.

### Alerting and notifications
- **Do not escape Go templates in HelmRelease values.** `{{ "{{" }}` is Helm chart template escaping, not HelmRelease values escaping. Values are data — Flux and Helm pass them through without template processing. Use `{{ .CommonLabels.alertname }}` directly. The double-escaping produces literal template text in Alertmanager output.
- **Use `templateFiles` for complex Alertmanager notification formatting.** Define named templates in `alertmanager.templateFiles` and reference them via `{{ template "name" . }}` in receiver configs. Cleaner than inline template logic.
- **Start with few alert rules and expand.** A noisy alerting setup trains operators to ignore alerts. Begin with 8-10 rules covering critical failures (node down, disk full, crash loops), then add warning-tier rules based on observed gaps.
