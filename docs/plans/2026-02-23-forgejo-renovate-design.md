# Forgejo + Renovate: Self-Hosted VCS and Dependency Automation

Roadmap steps 13 and 14. Forgejo replaces GitHub as the source of truth. Renovate automates dependency updates against Forgejo.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| VCS platform | Forgejo | Community-governed, lighter footprint, fully compatible ecosystem |
| Flux source migration | Full migration | One source of truth — Forgejo owns the repo |
| CI | Forgejo Actions | GitHub Actions compatible, runs on a local runner pod |
| GitHub backup | Push mirror | Forgejo auto-pushes to GitHub; zero-effort off-site backup |
| Renovate deployment | Self-hosted CronJob | Standard pattern, decoupled from CI, runs on a schedule |
| Implementation order | Forgejo first, then Renovate | Stable foundation before layering automation |

## Architecture

### Forgejo

Forgejo runs as infrastructure because Flux depends on it as its GitOps source.

**Components:**

- **Namespace:** `forgejo` (privileged PSA — runner requires DinD)
- **Helm chart:** `forgejo-helm/forgejo` (server only)
- **Database:** New database on the existing CloudNativePG postgres cluster, created manually via `psql` (not `initdb`, which runs only at cluster initialization; not the `Database` CRD, which lacks role creation)
- **Storage:** NFS PVC for git repositories, LFS objects, packages, attachments, and Actions artifacts
- **Ingress:** HTTPRoute at `git.catinthehack.ca` attached to `traefik-gateway`
- **Auth:** Authentik OIDC for browser login (SSO across all services); skip Kyverno forward-auth via label `auth.catinthehack.ca/skip: "true"` (git clients cannot use browser-based forward-auth)
- **Directory:** `kubernetes/infrastructure/forgejo/`

**Secrets:** The chart scopes `existingSecret` per feature, not as a single catch-all:

- `gitea.admin.existingSecret` — admin username and password
- `gitea.oauth[].existingSecret` — Authentik OIDC client credentials (client ID and secret)
- `gitea.additionalConfigSources` — database credentials injected as `app.ini` config fragments

All credentials stored in SOPS-encrypted Secrets.

**Hardening:** Key `app.ini` settings beyond defaults:
- `security.INSTALL_LOCK: true` — disables the setup wizard (prevents unauthenticated reconfiguration)
- `service.DISABLE_REGISTRATION: true` — admin creates accounts manually
- `session.COOKIE_SECURE: true` — cookies only sent over HTTPS

### Forgejo Actions Runner

The runner executes CI workflows using Docker-in-Docker. Native Kubernetes mode (ephemeral job pods) is not stable — DinD is the current production approach.

- **Helm chart:** Separate deployment via `wrenix/forgejo-runner` (the Forgejo server chart does not include the runner)
- **Registration:** Offline registration method — server-side `forgejo-cli actions register --secret <hex>`, runner-side `create-runner-file --secret <hex>`. Avoids runtime dependency on the API during startup. The `wrenix/forgejo-runner` chart handles this with an init container.
- **Privileged:** DinD sidecar requires `--privileged`, same justification as traefik and adguard namespaces
- **Namespace:** `forgejo`, alongside the server

**DinD mitigations:** Limit blast radius of privileged containers:
- Runner labels scope to `ubuntu-latest` only (no host-access labels)
- `container.valid_volumes: []` — blocks workflow volume mounts to the host
- `container.options: "--memory=1g --cpus=2"` — resource limits on spawned containers

**Workflow migration:** Port `.github/workflows/check.yml` to `.forgejo/workflows/check.yml`. Forgejo Actions is syntax-compatible, but `uses:` references default to `code.forgejo.org` instead of GitHub. Actions from `actions/*` on GitHub need full URL references (e.g., `uses: https://github.com/actions/checkout@v4`). Pin action refs to commit SHAs (matching the current GitHub workflow pattern).

### Flux Source

After cutover, Flux reconciles from Forgejo instead of GitHub.

**URL choice:** HTTPS external URL (`https://git.catinthehack.ca`) with token authentication. This depends on AdGuard DNS rewrite — if AdGuard goes down, Flux cannot pull. The in-cluster alternative (SSH or HTTP) was evaluated and rejected: Flux's source-controller blocks basic auth over plain HTTP, and SSH in-cluster adds complexity (key management, non-standard ports) that outweighs the DNS dependency risk for a homelab.

**Bootstrap command:** `flux bootstrap gitea` (not `flux bootstrap git`). The dedicated Gitea command works with Forgejo and handles deploy key registration via the API automatically. Requires a Forgejo PAT with `read:misc` and `write:repository` scopes.

```bash
flux bootstrap gitea \
  --owner=<username-or-org> \
  --repository=cloudlab \
  --hostname=git.catinthehack.ca \
  --branch=main \
  --path=kubernetes \
  --personal \
  --token-auth \
  --reconcile
```

The `--path=kubernetes` must match the existing `gotk-sync.yaml` configuration. The `--token-auth` flag uses HTTPS with the PAT (not SSH deploy keys). The `--reconcile` flag triggers immediate reconciliation after bootstrap.

**Critical: bootstrap overwrites `kustomization.yaml`.** The `flux bootstrap gitea` command regenerates `kubernetes/flux-system/kustomization.yaml`, removing custom entries. With `prune: true` on the flux-system Kustomization, Flux deletes all workloads whose resources are no longer listed. **Suspend the flux-system Kustomization before running bootstrap** (`flux suspend kustomization flux-system`), then re-add entries and resume after verification.

**Post-bootstrap verification:** Confirm `kubernetes/flux-system/kustomization.yaml` retains all six custom entries: `infrastructure.yaml`, `infrastructure-config.yaml`, `apps.yaml`, `cluster-policies.yaml`, `provider-alertmanager.yaml`, `alert-flux.yaml`. Re-add any that bootstrap reset. Resume the Kustomization (`flux resume kustomization flux-system`).

**Preserved secrets:** The `sops-age` Secret in `flux-system` is not managed by bootstrap and should survive re-bootstrap. Verify after cutover.

### Renovate

Self-hosted Renovate runs as a CronJob, creating PRs on Forgejo when dependencies have updates.

- **Namespace:** `renovate`
- **Helm chart:** OCI-only at `oci://ghcr.io/renovatebot/charts/renovate` (HelmRepository type `oci`)
- **Schedule:** Every 6 hours
- **Directory:** `kubernetes/apps/renovate/`
- **Platform:** `platform: "forgejo"` (not `gitea` — Forgejo support will be removed from the `gitea` platform in a future Renovate release)
- **Endpoint:** In-cluster service name `http://forgejo-http.forgejo.svc:3000` (bypasses Authentik forward-auth, which would challenge API calls)

**Configuration — two levels:**

1. **Global config** (Helm chart values / ConfigMap): tells Renovate where to look

   ```json
   {
     "platform": "forgejo",
     "endpoint": "http://forgejo-http.forgejo.svc:3000",
     "repositories": ["<owner>/cloudlab"]
   }
   ```

2. **In-repo config** (`renovate.json`): tells Renovate how to behave

   ```json
   {
     "$schema": "https://docs.renovatebot.com/renovate-schema.json",
     "extends": ["config:recommended"],
     "flux": {
       "managerFilePatterns": ["/kubernetes/.+\\.ya?ml$/"]
     }
   }
   ```

   The `managerFilePatterns` override is critical — the Flux manager's default only matches `gotk-components.yaml` and would silently ignore all HelmRelease files.

**What Renovate manages:**

| Source | Manager | Coverage |
|--------|---------|----------|
| HelmRelease chart versions | Flux | All charts (requires `managerFilePatterns` override) |
| Container image tags/digests | Flux | Images in HelmRelease values |
| `.mise.toml` tool versions | mise | Most tools; `age`, `kubeconform`, `kyverno`, `kube-linter`, and `aqua:`-prefixed tools are unsupported |
| Gateway API commit pin | Flux | GitRepository commit SHA (may need `packageRules` to limit to tagged releases) |
| Terraform provider versions | Terraform | `required_providers` blocks |

**Credentials:**

- **Forgejo PAT** — scopes: `repo` (read/write), `user` (read), `issue` (read/write), `organization` (read). Stored in SOPS-encrypted Secret.

## Flux Layers

| Component | Layer | Rationale |
|-----------|-------|-----------|
| Forgejo server | `kubernetes/infrastructure/` | Flux and Renovate depend on it |
| Forgejo runner | `kubernetes/infrastructure/` | Part of the Forgejo deployment |
| Forgejo HTTPRoute | `kubernetes/infrastructure/` (forgejo directory) | Co-located with the server; skip-auth label applied |
| Renovate | `kubernetes/apps/` | Workload consuming infrastructure |

## Implementation Phases

### Phase A: Deploy Forgejo

Code changes on a feature branch, merged via PR on GitHub (last PR before cutover).

1. Create `kubernetes/infrastructure/forgejo/` with namespace (privileged PSA), HelmRepository (server), HelmRepository (runner), HelmRelease (server with `INSTALL_LOCK`, `DISABLE_REGISTRATION`, `COOKIE_SECURE`), HelmRelease (runner with DinD mitigations), HTTPRoute (skip-auth label), SOPS Secrets
2. Write `.forgejo/workflows/check.yml` (ported from GitHub Actions, with commit-SHA-pinned `uses:` references)
3. Register `forgejo` in `kubernetes/infrastructure/kustomization.yaml`

### Phase B: Cutover

Manual operations — not GitOps. This changes Flux's own source.

1. Create Forgejo database and role manually via `psql` on the CloudNativePG pod
2. Fill in real credentials (admin password, database password) in SOPS secrets
3. Merge the feature branch PR on GitHub; Flux deploys Forgejo
4. Get runner registration token from Forgejo admin UI; fill in runner secret
5. Create a Forgejo PAT with `read:misc` and `write:repository` scopes
6. Push the repo to Forgejo (`git remote add forgejo && git push`)
7. Configure push mirror to GitHub (use fine-grained GitHub PAT with 90-day expiry)
8. Suspend flux-system Kustomization (`flux suspend kustomization flux-system`)
9. Run `flux bootstrap gitea` with `--path=kubernetes`, `--hostname=git.catinthehack.ca`, `--token-auth`, `--reconcile`
10. Verify `flux-system/kustomization.yaml` retains all six custom entries; re-add if needed
11. Resume flux-system Kustomization (`flux resume kustomization flux-system`)
12. Verify `sops-age` Secret in `flux-system` is intact
13. Verify all Flux Kustomizations reconcile from the new source
14. Configure branch protection and PR requirements in Forgejo (after bootstrap, not before — branch protection blocks the bootstrap push)
15. Push a test change and verify Forgejo Actions CI runs

**Rollback:** GitHub repo stays intact. Suspend flux-system Kustomization, re-bootstrap Flux back to GitHub, re-add custom entries, resume.

### Phase C: Deploy Renovate

First PR through Forgejo — validates the new workflow end to end.

1. Create `kubernetes/apps/renovate/` with namespace, HelmRepository (OCI type), HelmRelease, SOPS Secret, global config ConfigMap
2. Add `renovate.json` to the repo root with `managerFilePatterns` override
3. Register `renovate` in `kubernetes/apps/kustomization.yaml`
4. Verify Renovate creates its first PR on Forgejo

## Risks

| Risk | Mitigation |
|------|------------|
| Flux reconciliation gap during cutover | GitHub unchanged; re-bootstrap back if needed |
| Runner DinD requires privileged containers | Same pattern as traefik and adguard; PSA documented |
| Runner image bootstrap (chicken-and-egg) | First build is local; subsequent builds use CI |
| NFS storage for git repos | Same risk profile as Loki and PostgreSQL; fallback to hostPath |
| Forgejo Actions syntax gaps | Test workflow before cutover; adjust `uses:` references |
| AdGuard DNS dependency for Flux | Acceptable risk for homelab; GitHub repo intact for rollback |
| Renovate misses HelmRelease files | `managerFilePatterns` override in `renovate.json` |
| Authentik forward-auth blocks API calls | Renovate uses in-cluster service name, bypassing the Gateway |
| 5 mise tools unsupported by Renovate | Accept manual updates for `age`, `kubeconform`, `kyverno`, `kube-linter`, and `aqua:`-prefixed tools |
