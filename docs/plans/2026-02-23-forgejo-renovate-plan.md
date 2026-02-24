# Forgejo + Renovate Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy self-hosted Forgejo as the Git source of truth, migrate Flux from GitHub, and add Renovate for automated dependency updates.

**Architecture:** Forgejo runs as infrastructure (Flux depends on it). The runner uses DinD for CI. After cutover, Flux reconciles from Forgejo via HTTPS external URL with token auth. Renovate runs as an app-layer CronJob creating PRs on Forgejo.

**Tech Stack:** Forgejo Helm chart (v16.x), wrenix/forgejo-runner chart (v0.7.x), Renovate Helm chart (v46.x), CloudNativePG (manual psql), Flux bootstrap gitea, SOPS-encrypted secrets.

**Design doc:** `docs/plans/2026-02-23-forgejo-renovate-design.md`

---

## Phase A: Deploy Forgejo (PR to GitHub)

### Task 1: Forgejo namespace and secrets

**Files:**
- Create: `kubernetes/infrastructure/forgejo/namespace.yaml`
- Create: `kubernetes/infrastructure/forgejo/secret-admin.enc.yaml`
- Create: `kubernetes/infrastructure/forgejo/secret-db.enc.yaml`
- Create: `kubernetes/infrastructure/forgejo/secret-oauth.enc.yaml`

**Step 1: Create directory**

```bash
mkdir -p kubernetes/infrastructure/forgejo
```

**Step 2: Create namespace**

```yaml
# kubernetes/infrastructure/forgejo/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: forgejo
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

**Step 3: Create admin secret with placeholder values**

```yaml
# kubernetes/infrastructure/forgejo/secret-admin.enc.yaml (before encryption)
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: forgejo-admin
  namespace: forgejo
stringData:
  username: admin
  password: CHANGE_ME
```

Encrypt: `sops encrypt -i kubernetes/infrastructure/forgejo/secret-admin.enc.yaml`

**Step 4: Create database config secret with placeholder**

This Secret injects the database password into Forgejo's `app.ini` via `additionalConfigSources`. Keys are INI section names; values are the section content.

```yaml
# kubernetes/infrastructure/forgejo/secret-db.enc.yaml (before encryption)
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: forgejo-db-config
  namespace: forgejo
stringData:
  database: |
    PASSWD=CHANGE_ME
```

Encrypt: `sops encrypt -i kubernetes/infrastructure/forgejo/secret-db.enc.yaml`

**Step 5: Create OAuth secret with placeholder**

This Secret provides Authentik OIDC client credentials for browser-based SSO login. The `key` and `secret` field names are what the Forgejo Helm chart expects from `gitea.oauth[].existingSecret`.

```yaml
# kubernetes/infrastructure/forgejo/secret-oauth.enc.yaml (before encryption)
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: forgejo-oauth
  namespace: forgejo
stringData:
  key: CHANGE_ME_CLIENT_ID
  secret: CHANGE_ME_CLIENT_SECRET
```

Encrypt: `sops encrypt -i kubernetes/infrastructure/forgejo/secret-oauth.enc.yaml`

**Step 6: Commit**

```bash
git add kubernetes/infrastructure/forgejo/namespace.yaml \
        kubernetes/infrastructure/forgejo/secret-admin.enc.yaml \
        kubernetes/infrastructure/forgejo/secret-db.enc.yaml \
        kubernetes/infrastructure/forgejo/secret-oauth.enc.yaml
git commit -m "feat(forgejo): add namespace and placeholder secrets"
```

---

### Task 2: Forgejo HelmRepository and HelmRelease

**Files:**
- Create: `kubernetes/infrastructure/forgejo/helmrepository.yaml`
- Create: `kubernetes/infrastructure/forgejo/helmrelease.yaml`

**Step 1: Create HelmRepository**

```yaml
# kubernetes/infrastructure/forgejo/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: forgejo-helm
  namespace: forgejo
spec:
  interval: 60m
  url: https://codeberg.org/forgejo-helm/pages/
```

**Step 2: Create HelmRelease**

Pin to latest 16.x at implementation time (currently 16.2.0). Run `helm search repo forgejo-helm/forgejo --versions | head -5` to verify.

Key design decisions in the values:
- `fullnameOverride: forgejo` — clean service names (`forgejo-http`, `forgejo-ssh`)
- `httpRoute.enabled: false` — we create the HTTPRoute manually in the forgejo directory (need skip-auth label)
- `DEFAULT_ACTIONS_URL: https://github.com` — resolve action references to GitHub directly
- `additionalConfigSources` injects the database password from the SOPS Secret
- `persistence` on NFS for git repos, LFS, packages, and Actions artifacts
- `dependsOn: postgres-cluster` — database must exist before Forgejo starts

```yaml
# kubernetes/infrastructure/forgejo/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: forgejo
  namespace: forgejo
spec:
  interval: 30m
  timeout: 10m
  dependsOn:
    - name: postgres-cluster
      namespace: postgres
  chart:
    spec:
      chart: forgejo
      version: "16.2.0"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: forgejo-helm
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    fullnameOverride: forgejo

    gitea:
      admin:
        existingSecret: forgejo-admin
        email: admin@catinthehack.ca

      config:
        database:
          DB_TYPE: postgres
          HOST: postgres-cluster-rw.postgres.svc:5432
          NAME: forgejo
          USER: forgejo
          SSL_MODE: disable

        security:
          INSTALL_LOCK: true

        server:
          DOMAIN: git.catinthehack.ca
          ROOT_URL: https://git.catinthehack.ca/
          SSH_DOMAIN: git.catinthehack.ca
          SSH_PORT: "2222"
          START_SSH_SERVER: true
          LFS_START_SERVER: true

        service:
          DISABLE_REGISTRATION: true

        actions:
          ENABLED: true
          DEFAULT_ACTIONS_URL: https://github.com

        session:
          PROVIDER: db
          COOKIE_SECURE: true

        cache:
          ADAPTER: memory

        queue:
          TYPE: level

      oauth:
        - name: "Authentik"
          provider: "openidConnect"
          existingSecret: forgejo-oauth
          autoDiscoverUrl: "https://auth.catinthehack.ca/application/o/forgejo/.well-known/openid-configuration"

      additionalConfigSources:
        - secret:
            secretName: forgejo-db-config

    persistence:
      enabled: true
      size: 10Gi
      accessModes:
        - ReadWriteOnce
      storageClass: nfs
      annotations:
        helm.sh/resource-policy: keep

    httpRoute:
      enabled: false

    service:
      ssh:
        type: ClusterIP
        port: 2222

    resources:
      requests:
        cpu: 50m
        memory: 256Mi
      limits:
        memory: 512Mi
```

**Step 3: Commit**

```bash
git add kubernetes/infrastructure/forgejo/helmrepository.yaml \
        kubernetes/infrastructure/forgejo/helmrelease.yaml
git commit -m "feat(forgejo): add HelmRepository and HelmRelease"
```

---

### Task 3: Forgejo HTTPRoute

The HTTPRoute lives in the `forgejo/` directory alongside the server, not in `infrastructure-config/`. The Forgejo HelmRelease depends on the infrastructure layer (which installs Gateway API CRDs), so CRDs exist by the time the HTTPRoute is applied. Label `auth.catinthehack.ca/skip: "true"` skips Kyverno forward-auth injection — Forgejo has its own authentication and git clients cannot use browser-based auth.

**Files:**
- Create: `kubernetes/infrastructure/forgejo/httproute.yaml`

**Step 1: Create HTTPRoute**

```yaml
# kubernetes/infrastructure/forgejo/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: forgejo
  namespace: forgejo
  labels:
    auth.catinthehack.ca/skip: "true"
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "git.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: forgejo-http
          port: 3000
```

**Step 2: Commit**

```bash
git add kubernetes/infrastructure/forgejo/httproute.yaml
git commit -m "feat(forgejo): add HTTPRoute with skip-auth label"
```

---

### Task 4: Forgejo Actions runner

The runner uses Docker-in-Docker (DinD). Native Kubernetes job mode is not stable. The `wrenix/forgejo-runner` chart is OCI-only, so the HelmRepository uses `type: oci`. The runner registers with Forgejo via offline registration — an init container reads `CONFIG_TOKEN`, `CONFIG_INSTANCE`, and `CONFIG_NAME` from a Secret. DinD mitigations limit blast radius: `valid_volumes: []` blocks host mounts, `container.options` sets resource limits.

**Files:**
- Create: `kubernetes/infrastructure/forgejo/helmrepository-runner.yaml`
- Create: `kubernetes/infrastructure/forgejo/secret-runner.enc.yaml`
- Create: `kubernetes/infrastructure/forgejo/helmrelease-runner.yaml`

**Step 1: Create runner HelmRepository (OCI type)**

```yaml
# kubernetes/infrastructure/forgejo/helmrepository-runner.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: forgejo-runner
  namespace: forgejo
spec:
  type: oci
  interval: 60m
  url: oci://codeberg.org/wrenix/helm-charts
```

**Step 2: Create runner registration secret with placeholder**

The `CONFIG_TOKEN` is a 40-character hex string obtained from Forgejo's admin UI (Site Administration → Actions → Runners → Create new runner). The `CONFIG_INSTANCE` uses the in-cluster service name to avoid DNS dependency.

```yaml
# kubernetes/infrastructure/forgejo/secret-runner.enc.yaml (before encryption)
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: forgejo-runner-config
  namespace: forgejo
stringData:
  CONFIG_INSTANCE: http://forgejo-http.forgejo.svc:3000
  CONFIG_NAME: cloudlab-runner
  CONFIG_TOKEN: CHANGE_ME_40_CHAR_HEX
```

Encrypt: `sops encrypt -i kubernetes/infrastructure/forgejo/secret-runner.enc.yaml`

**Step 3: Create runner HelmRelease**

Pin to latest 0.7.x at implementation time (currently 0.7.1).

The `forgejo` namespace has `pod-security.kubernetes.io/enforce: privileged` PSA label (set in namespace.yaml from Task 1) because the DinD sidecar requires privileged mode.

```yaml
# kubernetes/infrastructure/forgejo/helmrelease-runner.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: forgejo-runner
  namespace: forgejo
spec:
  interval: 30m
  timeout: 5m
  dependsOn:
    - name: forgejo
      namespace: forgejo
  chart:
    spec:
      chart: forgejo-runner
      version: "0.7.1"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: forgejo-runner
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    replicaCount: 1

    runner:
      config:
        create: true
        existingInitSecret: forgejo-runner-config
        file:
          runner:
            capacity: 1
            timeout: 30m
            labels:
              - "ubuntu-latest:docker://catthehacker/ubuntu:act-latest"
          container:
            privileged: false
            docker_host: "-"
            valid_volumes: []
            options: "--memory=1g --cpus=2"

    dind:
      resources:
        requests:
          cpu: 100m
          memory: 512Mi
        limits:
          memory: 2Gi

    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        memory: 256Mi
```

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/forgejo/helmrepository-runner.yaml \
        kubernetes/infrastructure/forgejo/secret-runner.enc.yaml \
        kubernetes/infrastructure/forgejo/helmrelease-runner.yaml
git commit -m "feat(forgejo): add Actions runner with DinD"
```

---

### Task 5: Forgejo Actions workflow

Port the GitHub Actions workflow to Forgejo Actions. Key differences:
- `uses:` references resolve to `DEFAULT_ACTIONS_URL` (set to `https://github.com`), so existing references work without full URLs
- Pin action refs to commit SHAs (matching the current GitHub workflow pattern for supply chain security)
- `jdx/mise-action` installs mise and all tools from `.mise.toml`
- `permissions:` block is not needed (Forgejo Actions handles this differently)

**Files:**
- Create: `.forgejo/workflows/check.yml`

**Step 1: Create workflow directory and file**

```bash
mkdir -p .forgejo/workflows
```

```yaml
# .forgejo/workflows/check.yml
name: Check

on:
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      - uses: jdx/mise-action@6d1e696aa24c1aa1bcc1adea0212707c71ab78a8 # v3.6.1

      - name: Initialize Terraform providers
        working-directory: terraform
        run: terraform init -backend=false

      - name: Initialize tflint plugins
        working-directory: terraform
        run: tflint --init

      - name: Run checks
        run: mise run check
```

**Step 2: Commit**

```bash
git add .forgejo/workflows/check.yml
git commit -m "feat(forgejo): add Forgejo Actions CI workflow"
```

---

### Task 6: Register Forgejo and validate

**Files:**
- Create: `kubernetes/infrastructure/forgejo/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create Forgejo kustomization**

```yaml
# kubernetes/infrastructure/forgejo/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrepository-runner.yaml
  - secret-admin.enc.yaml
  - secret-db.enc.yaml
  - secret-oauth.enc.yaml
  - secret-runner.enc.yaml
  - helmrelease.yaml
  - helmrelease-runner.yaml
  - httproute.yaml
```

**Step 2: Register in infrastructure kustomization**

Add `forgejo` to `kubernetes/infrastructure/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway-api
  - cert-manager
  - traefik
  - nfs-provisioner
  - kyverno
  - adguard
  - monitoring
  - cloudnative-pg
  - postgres
  - authentik
  - forgejo
```

**Step 3: Validate**

```bash
mise run check
```

Expected: all checks pass. Kustomize builds successfully, kubeconform validates, gitleaks finds no secrets.

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/forgejo/kustomization.yaml \
        kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(forgejo): register in infrastructure kustomization"
```

---

## Phase B: Cutover (manual operations)

### Task 7: Create Forgejo database

The existing CloudNativePG cluster uses `initdb` which only runs at cluster initialization. Create the Forgejo database and role manually.

**Prerequisites:**
- Cluster is running: `kubectl get cluster -n postgres`
- Existing pod: `kubectl get pods -n postgres` (note the pod name, e.g., `postgres-cluster-1`)

**Step 1: Generate a database password**

```bash
openssl rand -base64 24
```

Save this password — you will need it in step 3.

**Step 2: Create the role and database**

```bash
kubectl exec -n postgres postgres-cluster-1 -c postgres -- \
  psql -c "CREATE ROLE forgejo LOGIN PASSWORD '<password-from-step-1>';"

kubectl exec -n postgres postgres-cluster-1 -c postgres -- \
  psql -c "CREATE DATABASE forgejo OWNER forgejo;"
```

Verify:

```bash
kubectl exec -n postgres postgres-cluster-1 -c postgres -- \
  psql -c "\du forgejo"

kubectl exec -n postgres postgres-cluster-1 -c postgres -- \
  psql -c "\l forgejo"
```

**Step 3: Fill in real credentials**

Update admin password (choose any password):

```bash
mise run sops:edit kubernetes/infrastructure/forgejo/secret-admin.enc.yaml
```

Replace `CHANGE_ME` in the `password` field.

Update database password (use the password from step 1):

```bash
mise run sops:edit kubernetes/infrastructure/forgejo/secret-db.enc.yaml
```

Replace `CHANGE_ME` in the `PASSWD=` line.

**Step 4: Commit encrypted secrets**

```bash
git add kubernetes/infrastructure/forgejo/secret-admin.enc.yaml \
        kubernetes/infrastructure/forgejo/secret-db.enc.yaml
git commit -m "feat(forgejo): fill in real credentials"
```

**Step 5: Push and let Flux deploy Forgejo**

Merge the feature branch PR on GitHub. Flux reconciles and deploys Forgejo.

Verify:

```bash
kubectl get pods -n forgejo
kubectl get helmrelease -n forgejo
```

Wait for the Forgejo server pod to be Running. The runner will crash-loop (placeholder token) — that is expected.

**Step 6: Verify Forgejo is accessible**

```bash
curl -I https://git.catinthehack.ca/
```

Expected: HTTP 200 (or 302 redirect to login).

Log in with the admin credentials to verify.

---

### Task 8: Configure Authentik OIDC for Forgejo

Set up Authentik as an OIDC provider so users can log in to Forgejo via SSO. This is separate from the forward-auth skip label (which handles git client access) — OIDC provides browser-based login.

**Step 1: Create OAuth2/OpenID Connect provider in Authentik**

In Authentik's web UI: Admin Interface → Providers → Create → OAuth2/OpenID Connect Provider.

- Name: `Forgejo`
- Authorization flow: `default-provider-authorization-explicit-consent`
- Client type: `Confidential`
- Redirect URIs: `https://git.catinthehack.ca/user/oauth2/Authentik/callback`
- Scopes: `openid`, `email`, `profile`

Note the **Client ID** and **Client Secret** — needed in step 3.

**Step 2: Create application in Authentik**

In Authentik's web UI: Admin Interface → Applications → Create.

- Name: `Forgejo`
- Slug: `forgejo`
- Provider: select the `Forgejo` provider from step 1
- Launch URL: `https://git.catinthehack.ca/`

**Step 3: Fill in OAuth credentials**

```bash
mise run sops:edit kubernetes/infrastructure/forgejo/secret-oauth.enc.yaml
```

Replace `CHANGE_ME_CLIENT_ID` with the Client ID and `CHANGE_ME_CLIENT_SECRET` with the Client Secret from step 1.

**Step 4: Commit and push**

```bash
git add kubernetes/infrastructure/forgejo/secret-oauth.enc.yaml
git commit -m "feat(forgejo): fill in Authentik OIDC credentials"
git push
```

Wait for Flux to reconcile. Verify OIDC login by visiting `https://git.catinthehack.ca/` — the login page should show an "Authentik" button.

---

### Task 9: Configure runner

**Step 1: Get runner registration token**

In Forgejo's web UI: Site Administration → Actions → Runners → Create new runner.

Copy the registration token (40-character hex string).

**Step 2: Fill in runner secret**

```bash
mise run sops:edit kubernetes/infrastructure/forgejo/secret-runner.enc.yaml
```

Replace `CHANGE_ME_40_CHAR_HEX` with the registration token.

**Step 3: Commit and push**

```bash
git add kubernetes/infrastructure/forgejo/secret-runner.enc.yaml
git commit -m "feat(forgejo): fill in runner registration token"
git push
```

**Step 4: Verify runner registers**

Wait for Flux to reconcile (~1-2 minutes), then:

```bash
kubectl get pods -n forgejo
```

The runner pod should be Running (not crash-looping). In Forgejo's web UI: Site Administration → Actions → Runners — the runner should appear as online.

---

### Task 10: Push repo and configure mirror

**Step 1: Create a Forgejo PAT**

In Forgejo's web UI: User Settings → Applications → Generate New Token.

Scopes: `read:misc`, `write:repository`.

Save the token — needed for flux bootstrap and push mirror.

**Step 2: Create the repository on Forgejo**

```bash
curl -X POST "https://git.catinthehack.ca/api/v1/user/repos" \
  -H "Authorization: token <FORGEJO_PAT>" \
  -H "Content-Type: application/json" \
  -d '{"name":"cloudlab","private":false,"default_branch":"main"}'
```

**Step 3: Push the repo to Forgejo**

```bash
git remote add forgejo https://git.catinthehack.ca/<ADMIN_USERNAME>/cloudlab.git
git push forgejo main
```

Authenticate with the Forgejo admin username and PAT as password.

**Step 4: Configure push mirror to GitHub**

In Forgejo's web UI: Repository Settings → Mirror Settings → Add push mirror.

- Remote Repository URL: `https://github.com/connormckinnon93/cloudlab.git`
- Authorization: Fine-grained GitHub PAT with `Contents: Read and write` scope on the `cloudlab` repo only, 90-day expiry
- Enable "Sync when new commits are pushed"

---

### Task 11: Flux bootstrap

This is the highest-risk step. Flux switches its git source from GitHub to Forgejo.

**Critical:** `flux bootstrap gitea` regenerates `kubernetes/flux-system/kustomization.yaml`, removing custom entries. With `prune: true`, Flux deletes all workloads whose resources are no longer listed. Suspend before bootstrap.

**Step 1: Suspend flux-system Kustomization**

```bash
flux suspend kustomization flux-system
```

This prevents Flux from acting on the kustomization.yaml changes until we re-add the custom entries.

**Step 2: Run flux bootstrap gitea**

```bash
export GITEA_TOKEN=<FORGEJO_PAT>

flux bootstrap gitea \
  --owner=<ADMIN_USERNAME> \
  --repository=cloudlab \
  --hostname=git.catinthehack.ca \
  --branch=main \
  --path=kubernetes \
  --personal \
  --token-auth \
  --reconcile
```

This updates the `flux-system` GitRepository source and pushes changes to Forgejo. The `--token-auth` flag uses HTTPS with the PAT (not SSH). The `--reconcile` flag triggers immediate reconciliation after bootstrap.

**Step 3: Verify and fix flux-system/kustomization.yaml**

Pull the changes that bootstrap pushed:

```bash
git pull forgejo main
```

Check `kubernetes/flux-system/kustomization.yaml`. It must contain all six custom entries:

```yaml
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
  - infrastructure.yaml
  - infrastructure-config.yaml
  - cluster-policies.yaml
  - apps.yaml
  - provider-alertmanager.yaml
  - alert-flux.yaml
```

If bootstrap reset the file, re-add the missing entries, commit, and push to Forgejo.

**Step 4: Resume flux-system Kustomization**

```bash
flux resume kustomization flux-system
```

Now Flux reconciles with the corrected kustomization.yaml.

**Step 5: Verify sops-age Secret**

```bash
kubectl get secret sops-age -n flux-system
```

Expected: the Secret exists. If missing, re-run `mise run flux:sops-key`.

**Step 6: Verify all Kustomizations reconcile**

```bash
flux get kustomizations
```

Expected: all Kustomizations show `Ready: True`. Wait up to 5 minutes for reconciliation.

If any Kustomization fails, check: `flux get kustomization <name> -o yaml`

---

### Task 12: Branch protection and CI test

**Step 1: Configure branch protection in Forgejo**

In Forgejo's web UI: Repository Settings → Branches → Add Branch Protection Rule.

- Branch name pattern: `main`
- Enable: "Require pull request before merging"
- Enable: "Require status checks to pass" (select the `check` workflow once it has run at least once)

**Step 2: Test CI end-to-end**

Create a test branch, push a trivial change, and open a PR:

```bash
git checkout -b test/ci-validation
echo "" >> README.md
git add README.md
git commit -m "test: verify Forgejo Actions CI"
git push forgejo test/ci-validation
```

Open a PR in Forgejo's web UI. Verify the `Check` workflow runs and passes.

After verification, close the PR without merging (or merge and clean up).

**Step 3: Decide on GitHub Actions**

The `.github/workflows/check.yml` still exists. When Forgejo mirrors to GitHub, pushes trigger GitHub Actions too. Options:

- Disable GitHub Actions on the GitHub repo (Settings → Actions → Disable)
- Delete `.github/workflows/check.yml` (removes CI from GitHub entirely)
- Leave it running as secondary CI (belt and suspenders)

Disable GitHub Actions on the GitHub repo to avoid redundant runs.

---

## Phase C: Deploy Renovate (PR to Forgejo)

### Task 13: Renovate namespace and secrets

**Files:**
- Create: `kubernetes/apps/renovate/namespace.yaml`
- Create: `kubernetes/apps/renovate/secret.enc.yaml`

**Step 1: Create directory and namespace**

```bash
mkdir -p kubernetes/apps/renovate
```

```yaml
# kubernetes/apps/renovate/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: renovate
```

**Step 2: Create secrets with placeholders**

The Secret contains:
- `RENOVATE_TOKEN` — Forgejo PAT for creating PRs (scopes: `repo` read/write, `user` read, `issue` read/write, `organization` read)

```yaml
# kubernetes/apps/renovate/secret.enc.yaml (before encryption)
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: renovate-secrets
  namespace: renovate
stringData:
  RENOVATE_TOKEN: CHANGE_ME
```

Encrypt: `sops encrypt -i kubernetes/apps/renovate/secret.enc.yaml`

**Step 3: Commit**

```bash
git add kubernetes/apps/renovate/namespace.yaml \
        kubernetes/apps/renovate/secret.enc.yaml
git commit -m "feat(renovate): add namespace and placeholder secrets"
```

---

### Task 14: Renovate HelmRepository and HelmRelease

**Files:**
- Create: `kubernetes/apps/renovate/helmrepository.yaml`
- Create: `kubernetes/apps/renovate/helmrelease.yaml`

**Step 1: Create HelmRepository (OCI type)**

```yaml
# kubernetes/apps/renovate/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: renovatebot
  namespace: renovate
spec:
  type: oci
  interval: 60m
  url: oci://ghcr.io/renovatebot/charts
```

**Step 2: Create HelmRelease**

Pin to latest 46.x at implementation time (currently 46.31.5). The chart deploys a CronJob by default.

The global config tells Renovate where to look (platform, endpoint, repositories). The in-repo `renovate.json` (Task 15) tells Renovate how to behave.

Renovate connects to Forgejo via in-cluster service name to bypass Authentik forward-auth (which would challenge API calls).

```yaml
# kubernetes/apps/renovate/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: renovate
  namespace: renovate
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: renovate
      version: "46.31.5"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: renovatebot
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    cronjob:
      schedule: "0 */6 * * *"

    existingSecret: renovate-secrets

    renovate:
      config: |
        {
          "platform": "forgejo",
          "endpoint": "http://forgejo-http.forgejo.svc:3000",
          "repositories": ["<ADMIN_USERNAME>/cloudlab"],
          "onboarding": false
        }

    resources:
      requests:
        cpu: 50m
        memory: 256Mi
      limits:
        memory: 1Gi
```

Replace `<ADMIN_USERNAME>` with the actual Forgejo admin username.

**Step 3: Commit**

```bash
git add kubernetes/apps/renovate/helmrepository.yaml \
        kubernetes/apps/renovate/helmrelease.yaml
git commit -m "feat(renovate): add HelmRepository and HelmRelease"
```

---

### Task 15: Renovate in-repo config

The `renovate.json` in the repo root configures Renovate's behavior. The critical override is `flux.managerFilePatterns` — without it, Renovate's Flux manager only matches `gotk-components.yaml` and silently ignores all HelmRelease files.

**Files:**
- Create: `renovate.json`

**Step 1: Create renovate.json**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "flux": {
    "managerFilePatterns": ["/kubernetes/.+\\.ya?ml$/"]
  },
  "packageRules": [
    {
      "description": "Group all Helm chart updates",
      "matchDatasources": ["helm"],
      "groupName": "helm charts"
    },
    {
      "description": "Group all container image updates",
      "matchDatasources": ["docker"],
      "groupName": "container images"
    }
  ]
}
```

**Step 2: Commit**

```bash
git add renovate.json
git commit -m "feat(renovate): add in-repo configuration"
```

---

### Task 16: Register Renovate and validate

**Files:**
- Create: `kubernetes/apps/renovate/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Step 1: Create Renovate kustomization**

```yaml
# kubernetes/apps/renovate/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - secret.enc.yaml
  - helmrelease.yaml
```

**Step 2: Register in apps kustomization**

```yaml
# kubernetes/apps/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - whoami
  - renovate
```

**Step 3: Validate**

```bash
mise run check
```

Expected: all checks pass.

**Step 4: Commit**

```bash
git add kubernetes/apps/renovate/kustomization.yaml \
        kubernetes/apps/kustomization.yaml
git commit -m "feat(renovate): register in apps kustomization"
```

---

### Task 17: Create Renovate credentials and verify

**Step 1: Create Forgejo PAT for Renovate**

In Forgejo's web UI: User Settings → Applications → Generate New Token.

Name: `renovate-bot`
Scopes: `repo` (read/write), `user` (read), `issue` (read/write), `organization` (read).

**Step 2: Fill in secrets**

```bash
mise run sops:edit kubernetes/apps/renovate/secret.enc.yaml
```

Replace `CHANGE_ME` with the Forgejo PAT.

**Step 3: Commit, push, and create PR**

```bash
git add kubernetes/apps/renovate/secret.enc.yaml
git commit -m "feat(renovate): fill in credentials"
git push forgejo HEAD
```

Open a PR on Forgejo. Verify CI passes. Merge.

**Step 4: Verify Renovate runs**

After Flux reconciles:

```bash
kubectl get cronjob -n renovate
kubectl get jobs -n renovate
```

Wait for the next scheduled run (or trigger manually):

```bash
kubectl create job --from=cronjob/renovate renovate-manual -n renovate
kubectl logs -n renovate job/renovate-manual -f
```

Expected: Renovate scans the repo, discovers dependencies, and creates PRs on Forgejo for any outdated versions.

---

## Phase D: Documentation

### Task 18: Update documentation

**Files:**
- Modify: `CLAUDE.md` — add Forgejo implementation notes, runner patterns, and deployment lessons
- Modify: `ARCHITECTURE.md` — add Forgejo and Renovate to infrastructure components and app list
- Modify: `README.md` — update roadmap (mark steps 13 and 14 complete), add Forgejo/Renovate tools

**Step 1: Update CLAUDE.md**

Add to Key Files table, Implementation Notes, and Deployment Lessons. Key notes:

- Forgejo chart `existingSecret` is scoped per feature (admin, oauth, additionalConfigSources)
- Runner uses DinD with privileged PSA (same pattern as traefik, adguard); mitigations: valid_volumes: [], container resource limits
- Runner registration via `existingInitSecret` with offline registration
- Forgejo Actions `DEFAULT_ACTIONS_URL` set to GitHub for direct action resolution
- Flux source uses HTTPS external URL with token auth
- Renovate `managerFilePatterns` override is critical for Flux manager
- Renovate uses in-cluster Forgejo endpoint to bypass forward-auth

**Step 2: Update ARCHITECTURE.md**

Add to infrastructure components table:

| Forgejo | Self-hosted Git with Actions CI, push mirror to GitHub |
| Renovate | Automated dependency updates via CronJob |

**Step 3: Update README.md roadmap**

Mark steps 13 (Gitea/Forgejo) and 14 (Renovate) as complete with strikethrough.

**Step 4: Commit**

```bash
git add CLAUDE.md ARCHITECTURE.md README.md
git commit -m "docs: add Forgejo and Renovate documentation"
```

**Step 5: Archive design and plan docs**

```bash
mv docs/plans/2026-02-23-forgejo-renovate-design.md docs/plans/archive/
mv docs/plans/2026-02-23-forgejo-renovate-plan.md docs/plans/archive/
git add docs/plans/
git commit -m "docs: archive Forgejo/Renovate design and plan"
```

---

## Rollback Plan

At any point during Phase B, if something breaks:

1. **Suspend flux-system Kustomization:** `flux suspend kustomization flux-system`
2. **Re-bootstrap Flux to GitHub:** `flux bootstrap github --owner=connormckinnon93 --repository=cloudlab --branch=main --path=kubernetes --personal`
3. **Re-add custom entries** to `kubernetes/flux-system/kustomization.yaml`
4. **Resume flux-system Kustomization:** `flux resume kustomization flux-system`
5. **Verify** `flux get kustomizations` — all reconciled

The GitHub repo is untouched throughout the cutover. Suspend before re-bootstrap to prevent pruning.

## Known Limitations

- **5 mise tools not updated by Renovate:** `age`, `kubeconform`, `kyverno`, `kube-linter`, and `aqua:`-prefixed tools. Update manually.
- **Database not managed by GitOps:** The Forgejo database and role are created manually. If the cluster is rebuilt, re-run the database creation commands from Task 7.
- **Runner image pulls from public registries:** CI jobs pull `catthehacker/ubuntu:act-latest` and GitHub Actions from the internet. Air-gapped operation requires mirroring these images.
