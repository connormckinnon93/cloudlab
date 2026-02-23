# Authentication Gateway — Design

## Goal

Provide a self-service identity portal and authentication gateway for all cluster services. Family members register, manage their profiles, enroll 2FA devices, and access services through SSO. A forward-auth proxy protects apps without native authentication. Apps that support OIDC authenticate directly.

## Approach

Five infrastructure components deployed in order:

1. **PostgreSQL** — shared database server via Bitnami Helm chart. Each application gets its own database and credentials. Future services (Gitea, Infisical) connect as clients.
2. **Redis** — shared instance via Bitnami Helm chart. Authentik uses it for caching and session storage. Future apps can use separate Redis databases (numbered 0–15).
3. **Authentik server** — identity provider, admin UI, user self-service portal at `auth.catinthehack.ca`. Connects to shared PostgreSQL and Redis.
4. **Proxy outpost** — separate Deployment running `ghcr.io/goauthentik/proxy`. Handles forward-auth requests from Traefik.
5. **Kyverno mutating policy** — auto-injects the Traefik ForwardAuth middleware annotation into every HTTPRoute unless explicitly opted out.

### Why Authentik over Authelia

Authelia lacks self-registration and a self-service user portal. Family members need to register themselves, manage their own profiles, reset passwords, and enroll 2FA devices. Authelia's file-based user store requires admin edits for every change. Authentik provides these features natively.

### Why Authentik over Pocket ID + oauth2-proxy

Pocket ID is an OIDC-only provider — it cannot protect apps without native OIDC support (Prometheus, Alertmanager, Alloy). Pairing it with oauth2-proxy adds a second component without matching Authentik's user management features.

### Why shared PostgreSQL and Redis

Future services (Gitea, Infisical) require PostgreSQL. Running one shared instance with per-app databases avoids duplicating infrastructure. Redis follows the same pattern. Both are lightweight on a single-node cluster.

### Why a separate proxy outpost

The embedded outpost runs inside the Authentik server process. A separate outpost Deployment provides clear separation between the identity provider and the auth proxy, aligns with Authentik's documented Kubernetes integration, and can be restarted independently.

### GitOps via blueprints

Authentik blueprints are declarative YAML files that define flows, providers, applications, and outposts. Mounted into the pod via ConfigMap, they apply on startup. All configuration lives in Git — the admin UI is for monitoring only, not configuration.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   authentik namespace                     │
│                                                          │
│  ┌──────────────────┐       ┌──────────────────────────┐ │
│  │  Authentik Server │       │  Proxy Outpost           │ │
│  │  ├─ OIDC provider │       │  (forward-auth endpoint) │ │
│  │  ├─ Admin UI      │       └──────────────────────────┘ │
│  │  ├─ User portal   │                                    │
│  │  └─ Worker        │                                    │
│  └────────┬──────────┘                                    │
│           │                                               │
└───────────┼───────────────────────────────────────────────┘
            │
     ┌──────┴──────┐
     ▼              ▼
┌─────────┐  ┌──────────┐
│ Postgres │  │  Redis   │
│ (shared) │  │ (shared) │
│ postgres │  │  redis   │
│namespace │  │namespace │
└─────────┘  └──────────┘
```

PostgreSQL and Redis live in their own namespaces as shared infrastructure. Each consumer gets isolated credentials and a dedicated database or index.

## Kubernetes Deployment

### File Structure

```
kubernetes/infrastructure/
├── kustomization.yaml              # add: postgres, redis, authentik
├── postgres/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── helmrepository.yaml         # bitnami charts
│   ├── helmrelease.yaml            # postgresql
│   └── secret.enc.yaml             # superuser password, per-app credentials
├── redis/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── helmrepository.yaml         # bitnami charts
│   ├── helmrelease.yaml            # redis
│   └── secret.enc.yaml             # redis password
├── authentik/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── helmrepository.yaml         # goauthentik charts
│   ├── helmrelease.yaml            # authentik server + worker
│   ├── secret.enc.yaml             # secret key, bootstrap token, DB creds, JWKS
│   ├── httproute.yaml              # auth.catinthehack.ca
│   ├── middleware.yaml             # Traefik ForwardAuth CRD
│   ├── blueprints-configmap.yaml   # all blueprint YAML mounted into pod
│   ├── outpost-deployment.yaml     # proxy outpost pod
│   ├── outpost-service.yaml        # proxy outpost ClusterIP
│   └── outpost-httproute.yaml      # outpost auth callback routes
```

The Kyverno mutating policy lives in `kubernetes/cluster-policies/` alongside existing policies.

### Dependency Chain

Within the infrastructure Kustomization, `dependsOn` in each HelmRelease enforces order:

```
postgres ─► redis ─► authentik
                        │
                        ▼
                   proxy outpost
                   (manual Deployment)
```

PostgreSQL and Redis have no dependency on each other, but chaining them avoids a race where Authentik starts before both are ready.

## Blueprints

Four blueprints stored in a single ConfigMap, mounted at `/blueprints/custom/`.

### 1. Authentication Flow

Login experience: username/password, then 2FA prompt, then session.

```yaml
- model: authentik_flows.flow
  identifiers:
    slug: default-authentication
  attrs:
    name: Authentication
    designation: authentication
    authentication: require_unauthenticated

- model: authentik_stages_identification.identificationstage
  identifiers:
    name: authentication-identification
  attrs:
    user_fields: [username, email]

- model: authentik_stages_password.passwordstage
  identifiers:
    name: authentication-password

- model: authentik_stages_authenticator_validate.authenticatorvalidatestage
  identifiers:
    name: authentication-mfa
  attrs:
    device_classes: [totp, webauthn]
    not_configured_action: skip

- model: authentik_stages_user_login.userloginstage
  identifiers:
    name: authentication-login
  attrs:
    session_duration: hours=24
```

`not_configured_action: skip` makes 2FA optional until enforced per-user or per-group. New family members log in immediately; they enroll 2FA later through the self-service portal.

### 2. Enrollment Flow

Self-registration: username, email, password.

```yaml
- model: authentik_flows.flow
  identifiers:
    slug: default-enrollment
  attrs:
    name: Enrollment
    designation: enrollment
    compatibility_mode: true

- model: authentik_stages_prompt.prompt
  identifiers:
    field_key: username
  attrs:
    label: Username
    type: username
    required: true
    order: 0

- model: authentik_stages_prompt.prompt
  identifiers:
    field_key: email
  attrs:
    label: Email
    type: email
    required: true
    order: 1

- model: authentik_stages_prompt.prompt
  identifiers:
    field_key: password
  attrs:
    label: Password
    type: password
    required: true
    order: 2

- model: authentik_stages_user_write.userwritestage
  identifiers:
    name: enrollment-user-write
  attrs:
    create_users_as_inactive: false
    create_users_group: !Find [authentik_core.group, [name, users]]
```

New users join the `users` group automatically. The admin account belongs to `admins`. Access policies reference these groups.

### 3. Forward-Auth Provider + Application

```yaml
- model: authentik_providers_proxy.proxyprovider
  identifiers:
    name: traefik-forward-auth
  attrs:
    authorization_flow: !Find [authentik_flows.flow, [slug, default-authentication]]
    mode: forward_single
    external_host: https://auth.catinthehack.ca
    access_token_validity: hours=24

- model: authentik_core.application
  identifiers:
    slug: traefik-forward-auth
  attrs:
    name: Cluster Services
    provider: !Find [authentik_providers_proxy.proxyprovider, [name, traefik-forward-auth]]
    meta_launch_url: blank://blank
```

`forward_single` mode protects all domains under `*.catinthehack.ca` through one outpost. No per-app provider definitions needed.

### 4. Outpost Definition

```yaml
- model: authentik_outposts.outpost
  identifiers:
    name: traefik-outpost
  attrs:
    type: proxy
    providers:
      - !Find [authentik_providers_proxy.proxyprovider, [name, traefik-forward-auth]]
    service_connection: !Find [authentik_outposts.kubernetesserviceconnection, [name, local]]
    config:
      authentik_host: https://auth.catinthehack.ca
      kubernetes_disabled: true
```

`kubernetes_disabled: true` prevents Authentik from auto-managing the outpost Deployment. The proxy pod is managed in Git via `outpost-deployment.yaml`.

## Traefik Forward-Auth Middleware

```yaml
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
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
```

Every request hits the outpost. The outpost checks the session cookie, redirects unauthenticated users to `auth.catinthehack.ca`, and passes identity headers downstream on success.

### Default-Deny via Kyverno

Gateway API has no native "apply this middleware to all routes." Traefik requires each HTTPRoute to reference the middleware via annotation. A Kyverno mutating policy auto-injects it:

```yaml
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

Any HTTPRoute without the label `auth.catinthehack.ca/skip: "true"` gets auth injected automatically.

### Excluded Routes

| Route | Reason |
|-------|--------|
| `auth.catinthehack.ca` (Authentik) | Login page cannot require login |
| Outpost callback paths | Part of the auth flow itself |

Everything else — Grafana, Prometheus, Alertmanager, Alloy, whoami, future apps — gets auth without changes to their manifests.

## Bootstrap Token

The Authentik Helm chart supports `authentik.bootstrap_token`, a static API token created on first boot. The proxy outpost uses this token to connect to the Authentik server. Both values come from the same SOPS-encrypted secret — everything deploys in one pass with no manual token extraction.

## Storage

### NFS PersistentVolumeClaims

| Component | Size | Purpose |
|-----------|------|---------|
| PostgreSQL | 5Gi | All application databases |
| Redis | 1Gi | Cache and session data |
| Authentik | 1Gi | Media uploads (icons, branding) |
| **Total** | **7Gi** | All on Synology NFS |

PostgreSQL is sized for multiple databases (Authentik, Gitea, Infisical), not just Authentik.

### Resource Estimates

| Component | Memory Request | Memory Limit |
|-----------|---------------|-------------|
| Authentik server | 256Mi | 512Mi |
| Authentik worker | 128Mi | 256Mi |
| PostgreSQL | 128Mi | 256Mi |
| Redis | 64Mi | 128Mi |
| Proxy outpost | 64Mi | 128Mi |
| **Total** | **~640Mi** | **~1.3Gi** |

Combined with the observability stack (~1.7Gi limit), ~3Gi total on a 32GB machine.

## OIDC for Future Apps

Apps that support native OIDC skip the forward-auth proxy and authenticate directly with Authentik:

| App | OIDC Support | Integration |
|-----|-------------|-------------|
| Grafana | Native | OIDC client blueprint, `auth.generic_oauth` in Helm values |
| Gitea/Forgejo | Native | OIDC client blueprint |
| Infisical | Native | OIDC client blueprint |
| Prometheus | None | Forward-auth only |
| Alertmanager | None | Forward-auth only |

Each OIDC client is a new blueprint entry added to Git. When an app supports OIDC, opt it out of forward-auth (add the skip label) and configure native OIDC instead.

## Implementation Order

Five sequential stages within a single branch:

1. **PostgreSQL** — namespace, HelmRepository, HelmRelease, SOPS secret. Verify: pod running, connect with `psql` via port-forward.
2. **Redis** — namespace, HelmRepository, HelmRelease, SOPS secret. Verify: pod running, `redis-cli ping` returns PONG.
3. **Authentik** — namespace, HelmRepository, HelmRelease, SOPS secret (secret key, bootstrap token, DB credentials, JWKS), HTTPRoute, blueprints ConfigMap. Verify: `auth.catinthehack.ca` loads the login page, enrollment flow works, admin account accesses the admin UI.
4. **Proxy outpost** — Deployment, Service, outpost HTTPRoute for callback paths. Verify: outpost logs show successful connection to Authentik, forward-auth endpoint responds.
5. **Default-deny middleware** — Traefik Middleware CRD, Kyverno mutating ClusterPolicy, opt-out label on Authentik's HTTPRoute. Verify: unauthenticated request to `whoami.catinthehack.ca` redirects to `auth.catinthehack.ca`, login succeeds and redirects back.

## Prerequisites

1. **Authentik database in PostgreSQL** — created via init script in the PostgreSQL HelmRelease values (`primary.initdb.scripts`). Credentials stored in SOPS.
2. **Authentik secret key** — random 50+ character string, stored in SOPS.
3. **Bootstrap token** — random UUID, stored in SOPS, shared between Authentik server and outpost.
4. **JWKS keypair** — RSA private key for OIDC token signing, generated with `openssl`, stored in SOPS.
5. **`/etc/hosts` entry** — `auth.catinthehack.ca` pointing to `192.168.20.100`.

## Out of Scope

- Per-app OIDC client configuration (added per app as deployed)
- Email/SMTP for password reset (admin resets passwords until SMTP is configured)
- Custom branding
- Rate limiting on the login page (private network)
- PostgreSQL backups (covered by step 25, PersistentVolume backups)

## Roadmap Updates

- **Step 12** — becomes "Authentik (identity provider + forward-auth gateway)"
- **Steps 13–15** — Gitea, Renovate, and Infisical use the shared PostgreSQL, Redis, and Authentik OIDC
- **New convention** — shared PostgreSQL and Redis are cluster infrastructure; future apps connect as clients with per-app databases and credentials

## Validation

1. **Flux reconciliation** — all new HelmReleases reconcile without errors. `mise run check` passes.
2. **Self-registration** — visit `auth.catinthehack.ca`, complete enrollment, log in with the new account.
3. **2FA enrollment** — from the user portal, enroll a TOTP or WebAuthn device.
4. **Forward-auth** — unauthenticated request to any `*.catinthehack.ca` service redirects to login. After login, redirects back.
5. **Opt-out** — Authentik's HTTPRoute is excluded from forward-auth (no redirect loop).
6. **Kyverno injection** — deploy a new HTTPRoute without the annotation; verify Kyverno injects the middleware.
7. **Groups** — admin account accesses all services; regular user account respects group-based restrictions.
