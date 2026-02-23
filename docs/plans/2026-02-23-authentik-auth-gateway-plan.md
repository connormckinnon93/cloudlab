# Authentication Gateway — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Authentik as the identity provider and forward-auth gateway for all cluster services.

**Architecture:** CloudNativePG provides shared PostgreSQL in a dedicated namespace. Authentik server + worker handle identity management and serve the user portal at `auth.catinthehack.ca`. A separate proxy outpost handles forward-auth for Traefik. Kyverno auto-injects the ForwardAuth middleware annotation into every HTTPRoute.

**Tech Stack:** CloudNativePG 0.27.1 (operator) + 0.5.0 (cluster), PostgreSQL 17, Authentik 2025.12.4, Kyverno (existing), Traefik (existing), Flux GitOps

---

### Design Changes from Original Document

The following changes apply based on research during planning:

1. **No Redis** — Authentik removed Redis in v2025.10. PostgreSQL handles caching, sessions, and task queuing. Redis deployment deferred until a future service needs it (YAGNI).
2. **CloudNativePG replaces Bitnami PostgreSQL** — Bitnami's free Helm chart registry (Docker Hub OCI) froze in August 2025. CloudNativePG is actively maintained, Kubernetes-native, and supports declarative database/role management for future services (Gitea, Infisical).
3. **No JWKS keypair prerequisite** — Authentik generates its own OIDC signing keys automatically.
4. **`existingSecret` pattern** — Authentik v2025.12.4 supports referencing a pre-existing Secret for all configuration via `authentik.existingSecret.secretName`.
5. **Blueprints mount at `/blueprints/mounted/`** — The Helm chart mounts blueprint ConfigMaps at `/blueprints/mounted/cm-{name}/`, not `/blueprints/custom/`.

### Updated Dependency Chain

```
cloudnative-pg operator (cnpg-system) ─► postgres cluster (postgres) ─► authentik (authentik)
                                                                              │
                                                                              ▼
                                                                         proxy outpost
                                                                        (manual Deployment)
```

### Updated File Structure

```
kubernetes/infrastructure/
├── kustomization.yaml              # add: cloudnative-pg, postgres, authentik
├── cloudnative-pg/
│   ├── kustomization.yaml
│   ├── namespace.yaml              # cnpg-system
│   ├── helmrepository.yaml         # cloudnative-pg charts
│   └── helmrelease.yaml            # CNPG operator
├── postgres/
│   ├── kustomization.yaml
│   ├── namespace.yaml              # postgres
│   ├── helmrelease.yaml            # CNPG cluster (cross-namespace sourceRef)
│   └── secret.enc.yaml             # authentik DB credentials
├── authentik/
│   ├── kustomization.yaml
│   ├── namespace.yaml              # authentik
│   ├── helmrepository.yaml         # goauthentik charts
│   ├── helmrelease.yaml            # authentik server + worker
│   ├── secret.enc.yaml             # secret key, bootstrap token, DB password
│   ├── httproute.yaml              # auth.catinthehack.ca
│   ├── blueprints-configmap.yaml   # all blueprint YAML
│   ├── outpost-secret.enc.yaml     # outpost API credentials
│   ├── outpost-deployment.yaml     # proxy outpost pod
│   ├── outpost-service.yaml        # proxy outpost ClusterIP
│   └── outpost-httproute.yaml      # outpost callback routes
kubernetes/cluster-policies/
│   ├── middleware-forward-auth.yaml              # Traefik ForwardAuth Middleware (in cluster-policies to avoid CRD race)
│   └── clusterpolicy-inject-forward-auth.yaml
```

### Prerequisites

Before implementing, the user must:

1. Add `/etc/hosts` entry: `192.168.20.100 auth.catinthehack.ca`
2. Fill in real credentials after each SOPS secret is committed (documented per task)

---

## Task 1: CloudNativePG Operator

**Files:**
- Create: `kubernetes/infrastructure/cloudnative-pg/namespace.yaml`
- Create: `kubernetes/infrastructure/cloudnative-pg/helmrepository.yaml`
- Create: `kubernetes/infrastructure/cloudnative-pg/helmrelease.yaml`
- Create: `kubernetes/infrastructure/cloudnative-pg/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`
- Modify: `kubernetes/flux-system/infrastructure.yaml` (increase timeout)

**Step 1: Create the namespace**

```yaml
# kubernetes/infrastructure/cloudnative-pg/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
```

**Step 2: Create the HelmRepository**

```yaml
# kubernetes/infrastructure/cloudnative-pg/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cloudnative-pg
  namespace: cnpg-system
spec:
  interval: 60m
  url: https://cloudnative-pg.github.io/charts
```

**Step 3: Create the HelmRelease**

```yaml
# kubernetes/infrastructure/cloudnative-pg/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cloudnative-pg
  namespace: cnpg-system
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: cloudnative-pg
      version: "0.27.1"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: cloudnative-pg
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 256Mi
    monitoring:
      podMonitorEnabled: false
```

**Step 4: Create the kustomization entry point**

```yaml
# kubernetes/infrastructure/cloudnative-pg/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
```

**Step 5: Register in infrastructure kustomization**

Add `cloudnative-pg` to `kubernetes/infrastructure/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway-api
  - cert-manager
  - traefik
  - nfs-provisioner
  - kyverno
  - monitoring
  - cloudnative-pg
```

**Step 6: Increase Flux infrastructure Kustomization timeout**

The new dependency chain (CNPG operator → PostgreSQL cluster → Authentik) takes longer than the original 5m timeout allows. Increase to 15m in `kubernetes/flux-system/infrastructure.yaml`:

```yaml
  timeout: 15m
```

Change only the `timeout` value from `5m` to `15m`. Leave all other fields unchanged.

**Step 7: Validate**

Run: `mise run check`
Expected: PASS

**Step 8: Commit**

```bash
git add kubernetes/infrastructure/cloudnative-pg/ kubernetes/infrastructure/kustomization.yaml kubernetes/flux-system/infrastructure.yaml
git commit -m "feat: add CloudNativePG operator for shared PostgreSQL"
```

---

## Task 2: PostgreSQL Cluster

**Files:**
- Create: `kubernetes/infrastructure/postgres/namespace.yaml`
- Create: `kubernetes/infrastructure/postgres/helmrelease.yaml`
- Create: `kubernetes/infrastructure/postgres/secret.enc.yaml`
- Create: `kubernetes/infrastructure/postgres/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create the namespace**

```yaml
# kubernetes/infrastructure/postgres/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: postgres
```

**Step 2: Create the credential Secret (pre-encryption)**

Write this YAML to `kubernetes/infrastructure/postgres/secret.enc.yaml`:

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/basic-auth
metadata:
  name: cnpg-authentik-credentials
  namespace: postgres
stringData:
  username: authentik
  password: CHANGE-ME-run-mise-run-sops-edit
```

Then encrypt: `sops encrypt -i kubernetes/infrastructure/postgres/secret.enc.yaml`

> **User action required after commit:** Run `mise run sops:edit kubernetes/infrastructure/postgres/secret.enc.yaml` and replace the password placeholder with a real password. Use the same password in the Authentik secret (Task 3).

**Step 3: Create the HelmRelease**

References the HelmRepository from `cnpg-system` namespace via cross-namespace `sourceRef`.

```yaml
# kubernetes/infrastructure/postgres/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: postgres-cluster
  namespace: postgres
spec:
  interval: 30m
  timeout: 5m
  dependsOn:
    - name: cloudnative-pg
      namespace: cnpg-system
  chart:
    spec:
      chart: cluster
      version: "0.5.0"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: cloudnative-pg
        namespace: cnpg-system
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    type: postgresql
    mode: standalone

    version:
      # Pin to latest 17.x patch at implementation time (check https://www.postgresql.org/docs/17/release.html)
      # As of 2026-02-23, latest is 17.8
      postgresql: "17.8"

    cluster:
      instances: 1

      storage:
        size: 5Gi
        storageClass: nfs

      walStorage:
        enabled: false

      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          memory: 256Mi

      postgresql:
        parameters:
          shared_buffers: "64MB"
          effective_cache_size: "128MB"
          work_mem: "4MB"
          maintenance_work_mem: "32MB"
          max_connections: "50"

      enableSuperuserAccess: false

      monitoring:
        enabled: false

      initdb:
        database: authentik
        owner: authentik
        secret:
          name: cnpg-authentik-credentials

    backups:
      enabled: false
```

Key values:
- `dependsOn` ensures the CNPG operator CRDs exist before this HelmRelease is reconciled
- `initdb.secret.name` references the SOPS-encrypted credential Secret
- `instances: 1` — single instance for homelab
- `walStorage.enabled: false` — NFS doesn't suit separate WAL storage
- `enableSuperuserAccess: false` — Authentik's `initdb` user has full ownership of its database; no superuser needed

Generated services:
- `postgres-cluster-rw.postgres.svc.cluster.local` (read-write, used by Authentik)
- `postgres-cluster-ro.postgres.svc.cluster.local` (read-only)
- `postgres-cluster-r.postgres.svc.cluster.local` (any instance)

**Step 4: Create the kustomization entry point**

```yaml
# kubernetes/infrastructure/postgres/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - secret.enc.yaml
  - helmrelease.yaml
```

**Step 5: Register in infrastructure kustomization**

Add `postgres` to `kubernetes/infrastructure/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway-api
  - cert-manager
  - traefik
  - nfs-provisioner
  - kyverno
  - monitoring
  - cloudnative-pg
  - postgres
```

**Step 6: Validate**

Run: `mise run check`
Expected: PASS

**Step 7: Commit**

```bash
git add kubernetes/infrastructure/postgres/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat: add shared PostgreSQL cluster via CloudNativePG"
```

---

## Task 3: Authentik Server

**Files:**
- Create: `kubernetes/infrastructure/authentik/namespace.yaml`
- Create: `kubernetes/infrastructure/authentik/helmrepository.yaml`
- Create: `kubernetes/infrastructure/authentik/helmrelease.yaml`
- Create: `kubernetes/infrastructure/authentik/secret.enc.yaml`
- Create: `kubernetes/infrastructure/authentik/blueprints-configmap.yaml`
- Create: `kubernetes/infrastructure/authentik/httproute.yaml`
- Create: `kubernetes/infrastructure/authentik/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create the namespace**

```yaml
# kubernetes/infrastructure/authentik/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: authentik
```

**Step 2: Create the HelmRepository**

```yaml
# kubernetes/infrastructure/authentik/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: authentik
  namespace: authentik
spec:
  interval: 60m
  url: https://charts.goauthentik.io
```

**Step 3: Create the Secret (pre-encryption)**

Write this YAML to `kubernetes/infrastructure/authentik/secret.enc.yaml`:

```yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: authentik-secrets
  namespace: authentik
stringData:
  AUTHENTIK_SECRET_KEY: CHANGE-ME-generate-random-50-char-string
  AUTHENTIK_BOOTSTRAP_TOKEN: CHANGE-ME-generate-random-uuid
  AUTHENTIK_BOOTSTRAP_PASSWORD: CHANGE-ME-set-admin-password
  AUTHENTIK_POSTGRESQL__HOST: postgres-cluster-rw.postgres.svc.cluster.local
  AUTHENTIK_POSTGRESQL__PORT: "5432"
  AUTHENTIK_POSTGRESQL__NAME: authentik
  AUTHENTIK_POSTGRESQL__USER: authentik
  AUTHENTIK_POSTGRESQL__PASSWORD: CHANGE-ME-must-match-postgres-secret
```

Then encrypt: `sops encrypt -i kubernetes/infrastructure/authentik/secret.enc.yaml`

> **User action required after commit:**
> 1. Run `mise run sops:edit kubernetes/infrastructure/authentik/secret.enc.yaml`
> 2. Set `AUTHENTIK_SECRET_KEY` to a random 50+ character string (`openssl rand -base64 60 | tr -d '\n'`)
> 3. Set `AUTHENTIK_BOOTSTRAP_TOKEN` to a random UUID (`uuidgen`)
> 4. Set `AUTHENTIK_BOOTSTRAP_PASSWORD` to the admin password
> 5. Set `AUTHENTIK_POSTGRESQL__PASSWORD` to the same password used in the postgres secret (Task 2)

**Step 4: Create the blueprints ConfigMap**

Four blueprints in numbered files for processing order. Authentik discovers all `.yaml` files in the mounted directory.

```yaml
# kubernetes/infrastructure/authentik/blueprints-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-blueprints
  namespace: authentik
data:
  01-authentication-flow.yaml: |
    version: 1
    metadata:
      name: Authentication Flow
    entries:
      - model: authentik_flows.flow
        id: auth-flow
        identifiers:
          slug: default-authentication
        attrs:
          name: Authentication
          designation: authentication
          authentication: require_unauthenticated

      - model: authentik_stages_identification.identificationstage
        id: auth-identification
        identifiers:
          name: authentication-identification
        attrs:
          user_fields:
            - username
            - email

      - model: authentik_stages_password.passwordstage
        id: auth-password
        identifiers:
          name: authentication-password
        attrs:
          backends:
            - authentik.core.auth.InbuiltBackend

      - model: authentik_stages_authenticator_validate.authenticatorvalidatestage
        id: auth-mfa
        identifiers:
          name: authentication-mfa
        attrs:
          device_classes:
            - totp
            - webauthn
          not_configured_action: skip

      - model: authentik_stages_user_login.userloginstage
        id: auth-login
        identifiers:
          name: authentication-login
        attrs:
          session_duration: hours=24

      - model: authentik_flows.flowstagebinding
        identifiers:
          target: !KeyOf auth-flow
          stage: !KeyOf auth-identification
        attrs:
          order: 10

      - model: authentik_flows.flowstagebinding
        identifiers:
          target: !KeyOf auth-flow
          stage: !KeyOf auth-password
        attrs:
          order: 20

      - model: authentik_flows.flowstagebinding
        identifiers:
          target: !KeyOf auth-flow
          stage: !KeyOf auth-mfa
        attrs:
          order: 30

      - model: authentik_flows.flowstagebinding
        identifiers:
          target: !KeyOf auth-flow
          stage: !KeyOf auth-login
        attrs:
          order: 40

  02-enrollment-flow.yaml: |
    version: 1
    metadata:
      name: Enrollment Flow
    entries:
      - model: authentik_core.group
        id: users-group
        identifiers:
          name: users
        attrs:
          name: users

      - model: authentik_flows.flow
        id: enrollment-flow
        identifiers:
          slug: default-enrollment
        attrs:
          name: Enrollment
          designation: enrollment
          compatibility_mode: true

      - model: authentik_stages_prompt.prompt
        id: prompt-username
        identifiers:
          field_key: username
        attrs:
          label: Username
          type: username
          required: true
          order: 0
          placeholder: Username
          placeholder_expression: false

      - model: authentik_stages_prompt.prompt
        id: prompt-email
        identifiers:
          field_key: email
        attrs:
          label: Email
          type: email
          required: true
          order: 1
          placeholder: Email
          placeholder_expression: false

      - model: authentik_stages_prompt.prompt
        id: prompt-password
        identifiers:
          field_key: password
        attrs:
          label: Password
          type: password
          required: true
          order: 2
          placeholder: Password
          placeholder_expression: false

      - model: authentik_stages_prompt.prompt
        id: prompt-password-repeat
        identifiers:
          field_key: password_repeat
        attrs:
          label: Password (repeat)
          type: password
          required: true
          order: 3
          placeholder: Password (repeat)
          placeholder_expression: false

      - model: authentik_stages_prompt.promptstage
        id: enrollment-prompt
        identifiers:
          name: enrollment-prompt
        attrs:
          fields:
            - !KeyOf prompt-username
            - !KeyOf prompt-email
            - !KeyOf prompt-password
            - !KeyOf prompt-password-repeat

      - model: authentik_stages_user_write.userwritestage
        id: enrollment-user-write
        identifiers:
          name: enrollment-user-write
        attrs:
          create_users_as_inactive: false
          create_users_group: !KeyOf users-group

      - model: authentik_stages_user_login.userloginstage
        id: enrollment-login
        identifiers:
          name: enrollment-login
        attrs:
          session_duration: hours=24

      - model: authentik_flows.flowstagebinding
        identifiers:
          target: !KeyOf enrollment-flow
          stage: !KeyOf enrollment-prompt
        attrs:
          order: 10

      - model: authentik_flows.flowstagebinding
        identifiers:
          target: !KeyOf enrollment-flow
          stage: !KeyOf enrollment-user-write
        attrs:
          order: 20

      - model: authentik_flows.flowstagebinding
        identifiers:
          target: !KeyOf enrollment-flow
          stage: !KeyOf enrollment-login
        attrs:
          order: 30

  03-forward-auth-provider.yaml: |
    version: 1
    metadata:
      name: Forward Auth Provider
    entries:
      - model: authentik_providers_proxy.proxyprovider
        id: forward-auth-provider
        identifiers:
          name: traefik-forward-auth
        attrs:
          authorization_flow: !Find [authentik_flows.flow, [slug, default-authentication]]
          mode: forward_domain
          external_host: https://auth.catinthehack.ca
          cookie_domain: catinthehack.ca
          access_token_validity: hours=24

      - model: authentik_core.application
        identifiers:
          slug: traefik-forward-auth
        attrs:
          name: Cluster Services
          provider: !KeyOf forward-auth-provider
          meta_launch_url: "blank://blank"

  04-proxy-outpost.yaml: |
    version: 1
    metadata:
      name: Proxy Outpost
    entries:
      - model: authentik_outposts.outpost
        identifiers:
          name: traefik-outpost
        attrs:
          type: proxy
          providers:
            - !Find [authentik_providers_proxy.proxyprovider, [name, traefik-forward-auth]]
          config:
            authentik_host: https://auth.catinthehack.ca
            kubernetes_disabled: true
```

Key details:
- The design's blueprint snippets were missing stage bindings (`flowstagebinding`) and the prompt stage (`promptstage`) — both are required for flows to function
- `not_configured_action: skip` makes 2FA optional until a user enrolls a device
- `password_repeat` field added for enrollment UX
- Within-file references use `!KeyOf` with `id` fields (resolves locally, no database query). Cross-file references (e.g., blueprint 03 referencing the auth flow from 01, blueprint 04 referencing the provider from 03) use `!Find` (database lookup by identifier).
- `kubernetes_disabled: true` prevents Authentik from auto-managing the outpost Deployment
- `enrollment-login` stage auto-logs the user in after registration

**Step 5: Create the HelmRelease**

```yaml
# kubernetes/infrastructure/authentik/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: authentik
  namespace: authentik
spec:
  interval: 30m
  timeout: 10m
  dependsOn:
    - name: postgres-cluster
      namespace: postgres
  chart:
    spec:
      chart: authentik
      version: "2025.12.4"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: authentik
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    authentik:
      existingSecret:
        secretName: authentik-secrets

    postgresql:
      enabled: false

    server:
      replicas: 1
      resources:
        requests:
          cpu: 50m
          memory: 256Mi
        limits:
          memory: 512Mi

    worker:
      enabled: true
      replicas: 1
      resources:
        requests:
          cpu: 25m
          memory: 128Mi
        limits:
          memory: 256Mi

    blueprints:
      configMaps:
        - authentik-blueprints

    global:
      env:
        - name: AUTHENTIK_ERROR_REPORTING__ENABLED
          value: "false"
```

Key values:
- `existingSecret.secretName` points to the SOPS-encrypted Secret (no inline credentials)
- `postgresql.enabled: false` disables the bundled Bitnami PostgreSQL subchart
- No Redis configuration — Authentik 2025.12.4 does not use Redis
- `blueprints.configMaps` mounts the blueprint ConfigMap into the worker pod at `/blueprints/mounted/cm-authentik-blueprints/`
- `timeout: 10m` because Authentik's initial database migration takes time

**Step 6: Create the HTTPRoute**

```yaml
# kubernetes/infrastructure/authentik/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: authentik
  namespace: authentik
  labels:
    auth.catinthehack.ca/skip: "true"
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "auth.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: authentik-server
          port: 80
```

The `auth.catinthehack.ca/skip: "true"` label excludes this route from the Kyverno forward-auth injection — the login page cannot require login.

**Step 7: Create the kustomization entry point**

```yaml
# kubernetes/infrastructure/authentik/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - secret.enc.yaml
  - blueprints-configmap.yaml
  - helmrelease.yaml
  - httproute.yaml
```

**Step 8: Register in infrastructure kustomization**

Add `authentik` to `kubernetes/infrastructure/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway-api
  - cert-manager
  - traefik
  - nfs-provisioner
  - kyverno
  - monitoring
  - cloudnative-pg
  - postgres
  - authentik
```

**Step 9: Validate**

Run: `mise run check`
Expected: PASS

**Step 10: Commit**

```bash
git add kubernetes/infrastructure/authentik/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat: add Authentik identity provider with blueprints"
```

---

## Task 4: Proxy Outpost

**Files:**
- Create: `kubernetes/infrastructure/authentik/outpost-secret.enc.yaml`
- Create: `kubernetes/infrastructure/authentik/outpost-deployment.yaml`
- Create: `kubernetes/infrastructure/authentik/outpost-service.yaml`
- Create: `kubernetes/infrastructure/authentik/outpost-httproute.yaml`
- Modify: `kubernetes/infrastructure/authentik/kustomization.yaml`

**Step 1: Create the outpost Secret (pre-encryption)**

Write this YAML to `kubernetes/infrastructure/authentik/outpost-secret.enc.yaml`:

```yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: authentik-outpost-api
  namespace: authentik
stringData:
  AUTHENTIK_HOST: https://auth.catinthehack.ca
  AUTHENTIK_INSECURE: "true"
  AUTHENTIK_TOKEN: CHANGE-ME-must-match-bootstrap-token
```

Then encrypt: `sops encrypt -i kubernetes/infrastructure/authentik/outpost-secret.enc.yaml`

> **User action required after commit:** Run `mise run sops:edit kubernetes/infrastructure/authentik/outpost-secret.enc.yaml` and set `AUTHENTIK_TOKEN` to the same value as `AUTHENTIK_BOOTSTRAP_TOKEN` from the Authentik secret (Task 3).

Notes:
- `AUTHENTIK_HOST` is the external URL — the outpost uses it for both API communication and browser redirects
- `AUTHENTIK_INSECURE: "true"` skips TLS verification for in-cluster communication that hairpins through the ingress

**Step 2: Create the outpost Deployment**

```yaml
# kubernetes/infrastructure/authentik/outpost-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authentik-outpost
  namespace: authentik
  labels:
    app.kubernetes.io/instance: traefik-outpost
    app.kubernetes.io/name: authentik-outpost
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: traefik-outpost
      app.kubernetes.io/name: authentik-outpost
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: traefik-outpost
        app.kubernetes.io/name: authentik-outpost
    spec:
      containers:
        - name: proxy
          image: ghcr.io/goauthentik/proxy:2025.12.4
          ports:
            - containerPort: 9000
              name: http
              protocol: TCP
            - containerPort: 9443
              name: https
              protocol: TCP
          envFrom:
            - secretRef:
                name: authentik-outpost-api
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 128Mi
```

**Step 3: Create the outpost Service**

```yaml
# kubernetes/infrastructure/authentik/outpost-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost
  namespace: authentik
  labels:
    app.kubernetes.io/instance: traefik-outpost
    app.kubernetes.io/name: authentik-outpost
spec:
  selector:
    app.kubernetes.io/instance: traefik-outpost
    app.kubernetes.io/name: authentik-outpost
  ports:
    - name: http
      port: 9000
      protocol: TCP
      targetPort: http
    - name: https
      port: 9443
      protocol: TCP
      targetPort: https
  type: ClusterIP
```

**Step 4: Create the outpost HTTPRoute**

Routes the outpost callback paths through the Gateway. In `forward_domain` mode, these paths are served on the auth domain. The `cookie_domain: catinthehack.ca` in the provider ensures the auth cookie is shared across all subdomains.

```yaml
# kubernetes/infrastructure/authentik/outpost-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: authentik-outpost
  namespace: authentik
  labels:
    auth.catinthehack.ca/skip: "true"
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "auth.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /outpost.goauthentik.io
      backendRefs:
        - name: authentik-outpost
          port: 9000
```

The `auth.catinthehack.ca/skip: "true"` label excludes this route from forward-auth injection — callback paths are part of the auth flow itself. The `/outpost.goauthentik.io` prefix is more specific than `/`, so Gateway API routes these requests to the outpost instead of the Authentik server.

**Step 5: Update the authentik kustomization**

```yaml
# kubernetes/infrastructure/authentik/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - secret.enc.yaml
  - blueprints-configmap.yaml
  - helmrelease.yaml
  - httproute.yaml
  - outpost-secret.enc.yaml
  - outpost-deployment.yaml
  - outpost-service.yaml
  - outpost-httproute.yaml
```

**Step 6: Validate**

Run: `mise run check`
Expected: PASS

**Step 7: Commit**

```bash
git add kubernetes/infrastructure/authentik/
git commit -m "feat: add proxy outpost for forward-auth"
```

---

## Task 5: ForwardAuth Middleware + Kyverno Policy

**Files:**
- Create: `kubernetes/cluster-policies/middleware-forward-auth.yaml`
- Create: `kubernetes/cluster-policies/clusterpolicy-inject-forward-auth.yaml`
- Modify: `kubernetes/cluster-policies/kustomization.yaml`

The Middleware lives in `cluster-policies/` instead of `infrastructure/authentik/` to avoid a CRD race condition. The infrastructure Kustomization applies all resources in a single server-side dry-run pass. Since `middleware.yaml` would be the first `traefik.io/v1alpha1` resource in the infrastructure layer, Flux would reject it if Traefik's HelmRelease hasn't installed the Middleware CRD yet during that pass — the same deadlock pattern as cert-manager CRD bootstrapping. Placing it in `cluster-policies/` (which depends on infrastructure) guarantees Traefik CRDs exist before the Middleware is applied.

**Step 1: Create the Traefik Middleware**

```yaml
# kubernetes/cluster-policies/middleware-forward-auth.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forward-auth
  namespace: authentik
spec:
  forwardAuth:
    address: http://authentik-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-entitlements
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
      - X-authentik-jwt
      - X-authentik-meta-jwks
      - X-authentik-meta-outpost
      - X-authentik-meta-provider
      - X-authentik-meta-app
      - X-authentik-meta-version
```

The response headers pass identity information to downstream services. The full list comes from the Authentik documentation (the design document had a subset).

Note: The Middleware is a namespaced resource in `authentik` namespace, but lives in the `cluster-policies/` Flux Kustomization directory. The `cluster-policies` Kustomization does not set `targetNamespace`, so the resource's own namespace field is respected.

**Step 2: Create the Kyverno ClusterPolicy**

```yaml
# kubernetes/cluster-policies/clusterpolicy-inject-forward-auth.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-authentik-forward-auth
spec:
  rules:
    - name: add-forward-auth-middleware
      match:
        any:
          - resources:
              kinds:
                - HTTPRoute
      exclude:
        any:
          - resources:
              selector:
                matchLabels:
                  auth.catinthehack.ca/skip: "true"
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              traefik.io/middleware: authentik-authentik-forward-auth@kubernetescrd
```

How it works:
- Every HTTPRoute CREATE/UPDATE request passes through Kyverno's mutating admission webhook
- Kyverno adds the `traefik.io/middleware` annotation unless the route has the opt-out label
- The mutation fires BEFORE Kubernetes SSA processing, so Flux SSA never sees a request without the annotation — no SSA conflict
- The annotation value `authentik-authentik-forward-auth@kubernetescrd` follows Traefik's `{namespace}-{name}@kubernetescrd` convention

Opted-out routes (with `auth.catinthehack.ca/skip: "true"` label):
- `authentik` HTTPRoute — login page cannot require login
- `authentik-outpost` HTTPRoute — callback paths are part of the auth flow

**Step 3: Update the cluster-policies kustomization**

```yaml
# kubernetes/cluster-policies/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - clusterpolicy-verify-images.yaml
  - middleware-forward-auth.yaml
  - clusterpolicy-inject-forward-auth.yaml
```

**Step 4: Validate**

Run: `mise run check`
Expected: PASS

**Step 5: Commit**

```bash
git add kubernetes/cluster-policies/
git commit -m "feat: add forward-auth middleware with default-deny Kyverno policy"
```

---

## Task 6: Update Design Document

Update the design document to reflect changes discovered during planning.

**Files:**
- Modify: `docs/plans/2026-02-23-authentik-auth-gateway-design.md`

**Changes:**

1. Update the "Approach" section — replace "Five infrastructure components" with "Four infrastructure components" (Redis removed), replace PostgreSQL bullet with CloudNativePG description
2. Remove Redis bullet from the Approach list
3. Add a "### Why CloudNativePG over Bitnami PostgreSQL" section explaining the frozen registry
4. Remove the "### Why shared PostgreSQL and Redis" section — replace with "### Why shared PostgreSQL" (Redis deferred)
5. Update the Architecture diagram — remove Redis box
6. Update the File Structure — replace `postgres/` with `cloudnative-pg/` + `postgres/`, remove `redis/`
7. Update the Dependency Chain — remove Redis from the chain
8. Update Storage table — remove Redis row
9. Update Resource Estimates — remove Redis row, update PostgreSQL values
10. Update Prerequisites — remove JWKS keypair, update PostgreSQL description to reference CloudNativePG
11. Update Implementation Order — remove Redis stage, update PostgreSQL stage

**Validate:**

Run: `mise run check`
Expected: PASS

**Commit:**

```bash
git add docs/plans/2026-02-23-authentik-auth-gateway-design.md
git commit -m "docs: update auth gateway design for CloudNativePG and no Redis"
```

---

## Task 7: Update CLAUDE.md

Add implementation notes for the new components.

**Files:**
- Modify: `CLAUDE.md`

**Add these entries to the Implementation Notes section:**

- **CloudNativePG operator**: Runs in `cnpg-system` namespace, installs Cluster, Backup, ScheduledBackup, Pooler, and Database CRDs. Manages PostgreSQL instances across all namespaces.
- **Shared PostgreSQL**: CloudNativePG cluster in `postgres` namespace. Single instance on NFS. Same fsync risk as Loki — fallback to hostPath on local NVMe if corruption occurs. Services: `postgres-cluster-rw.postgres.svc` (read-write), `postgres-cluster-ro.postgres.svc` (read-only). Future services (Gitea, Infisical) add databases via the `Database` CRD or by updating the cluster chart values with additional `roles` entries.
- **Authentik existingSecret**: All credentials stored in a single SOPS-encrypted Secret (`authentik-secrets`). The chart reads `AUTHENTIK_*` environment variables from this Secret via `existingSecret.secretName`. No inline values in HelmRelease.
- **Authentik blueprints**: Mounted via `blueprints.configMaps` in HelmRelease values. Chart mounts at `/blueprints/mounted/cm-{name}/`, not `/blueprints/custom/`. Only the worker pod processes blueprints. Files numbered (`01-`, `02-`) for processing order.
- **Authentik removed Redis**: As of v2025.10, PostgreSQL handles caching, sessions, and task queuing. No Redis configuration exists in the chart or application. Redis deployment deferred until a future service requires it.
- **Proxy outpost**: Manual Deployment using `ghcr.io/goauthentik/proxy:{version}`. Pin image tag to match Authentik server version. Connects to Authentik via `AUTHENTIK_HOST` (external URL) with `AUTHENTIK_INSECURE=true` for in-cluster hairpin routing. `AUTHENTIK_TOKEN` must match `AUTHENTIK_BOOTSTRAP_TOKEN`.
- **Kyverno forward-auth mutation**: ClusterPolicy `inject-authentik-forward-auth` adds `traefik.io/middleware` annotation to all HTTPRoutes via mutating admission webhook. Fires before SSA processing — no conflict with Flux reconciliation. Opt out with label `auth.catinthehack.ca/skip: "true"`.
- **Bitnami Helm charts frozen**: Docker Hub OCI registry (`oci://registry-1.docker.io/bitnamicharts`) stopped receiving updates August 2025. Container images also frozen. Use alternative charts (CloudNativePG for PostgreSQL) or pin to last available versions with image overrides.

**Add to Key Files table:**

| `kubernetes/infrastructure/cloudnative-pg/` | CloudNativePG operator (shared PostgreSQL infrastructure) |
| `kubernetes/infrastructure/postgres/` | PostgreSQL cluster instance via CloudNativePG |
| `kubernetes/infrastructure/authentik/` | Authentik identity provider, proxy outpost, forward-auth middleware |
| `kubernetes/cluster-policies/clusterpolicy-inject-forward-auth.yaml` | Kyverno policy: auto-inject forward-auth on all HTTPRoutes |

**Validate:**

Run: `mise run check`
Expected: PASS

**Commit:**

```bash
git add CLAUDE.md
git commit -m "docs: add auth gateway implementation notes to CLAUDE.md"
```

---

## Deployment Verification

After all tasks are committed and the branch is pushed, verify on the live cluster:

1. **Flux reconciliation** — `mise run check` passes. All new HelmReleases reconcile without errors.
2. **PostgreSQL** — Pod running in `postgres` namespace. Connect with `kubectl exec` or port-forward and `psql` to verify the `authentik` database exists.
3. **Authentik** — `auth.catinthehack.ca` loads the login page. Admin account (`akadmin`) can access the admin UI at `auth.catinthehack.ca/if/admin/`.
4. **Self-registration** — Visit `auth.catinthehack.ca`, complete enrollment flow, log in with new account.
5. **Outpost** — Outpost logs show successful connection to Authentik (`kubectl logs -n authentik deploy/authentik-outpost`). Forward-auth endpoint responds at `http://authentik-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik`.
6. **Force reconciliation of existing routes** — After the Kyverno policy is active, force Flux to re-apply existing HTTPRoutes so they pick up the middleware annotation: `flux reconcile kustomization apps --with-source`. Kyverno's mutating webhook only fires on CREATE/UPDATE — without this step, existing routes (e.g. whoami) remain unprotected until the next scheduled reconciliation (up to 10 minutes).
7. **Forward-auth** — Unauthenticated request to `whoami.catinthehack.ca` redirects to `auth.catinthehack.ca`. Login succeeds and redirects back.
8. **Opt-out** — Authentik's HTTPRoute is excluded from forward-auth (no redirect loop on `auth.catinthehack.ca`).
9. **Kyverno injection** — Deploy a test HTTPRoute without the annotation; verify Kyverno injects the middleware (`kubectl get httproute -A -o yaml | grep traefik.io/middleware`).
10. **Rotate outpost token** — The outpost initially uses the bootstrap token (full admin API access). After blueprints have applied and the outpost object exists in Authentik, replace it with the scoped outpost service account token:
    1. Open the Authentik admin UI at `auth.catinthehack.ca/if/admin/`
    2. Navigate to Applications → Outposts → `traefik-outpost`
    3. Copy the auto-generated service account token
    4. Update the outpost secret: `mise run sops:edit kubernetes/infrastructure/authentik/outpost-secret.enc.yaml`
    5. Replace the `AUTHENTIK_TOKEN` value with the scoped token
    6. Commit and push — Flux will restart the outpost pod with the new token

## Credential Checklist

After committing all tasks, fill in real credentials:

| Secret | Command | Values to Set |
|--------|---------|---------------|
| PostgreSQL credentials | `mise run sops:edit kubernetes/infrastructure/postgres/secret.enc.yaml` | `password` — generate with `openssl rand -base64 32` |
| Authentik secrets | `mise run sops:edit kubernetes/infrastructure/authentik/secret.enc.yaml` | `AUTHENTIK_SECRET_KEY` — `openssl rand -base64 60 \| tr -d '\n'`; `AUTHENTIK_BOOTSTRAP_TOKEN` — `uuidgen`; `AUTHENTIK_BOOTSTRAP_PASSWORD` — admin password; `AUTHENTIK_POSTGRESQL__PASSWORD` — must match postgres secret |
| Outpost API (initial) | `mise run sops:edit kubernetes/infrastructure/authentik/outpost-secret.enc.yaml` | `AUTHENTIK_TOKEN` — initially set to `AUTHENTIK_BOOTSTRAP_TOKEN` value; replace with scoped outpost token post-deployment (see verification step 10) |
