# Headlamp OIDC Blueprint Design

## Goal

Automate Headlamp's OIDC integration with Authentik so that deploying the cluster creates the OAuth2 provider, application, and credentials without manual UI configuration.

## Problem

Headlamp already has OIDC configuration in its HelmRelease, but the Authentik side (OAuth2 provider and application) must be created manually through the Authentik admin UI. The OIDC client ID and secret in both Secrets contain placeholder values. This design eliminates that manual step.

## Constraints

- The repository is publicly visible. Credentials must never appear in plaintext.
- Authentik blueprints run inside the worker pod and can read environment variables via `!Env`.
- Both Secrets (Authentik and Headlamp) are SOPS-encrypted.

## Approach: `!Env` with Shared SOPS Credentials

Generate a client ID and secret once with `openssl rand`. Store the same values in two SOPS-encrypted Secrets: one in the `authentik` namespace (read by the Authentik worker via `global.env`) and one in the `headlamp` namespace (read by Flux `valuesFrom`). The blueprint references credentials through `!Env`, keeping the ConfigMap free of secrets.

### Credential Flow

```
openssl rand -hex 20  →  client_id
openssl rand -hex 40  →  client_secret
        │
        ├──→  authentik/secret.enc.yaml  (SOPS)
        │       HEADLAMP_OIDC_CLIENT_ID
        │       HEADLAMP_OIDC_CLIENT_SECRET
        │           │
        │           ▼
        │     HelmRelease global.env (secretKeyRef)
        │           │
        │           ▼
        │     Worker pod env vars
        │           │
        │           ▼
        │     Blueprint 03: !Env [HEADLAMP_OIDC_CLIENT_ID]
        │                   !Env [HEADLAMP_OIDC_CLIENT_SECRET]
        │
        └──→  headlamp/secret.enc.yaml  (SOPS)
                HEADLAMP_CONFIG_OIDC_CLIENT_ID
                HEADLAMP_CONFIG_OIDC_CLIENT_SECRET
                    │
                    ▼
              HelmRelease valuesFrom (targetPath)
                    │
                    ▼
              Headlamp pod config.oidc
```

### Blueprint 03: Headlamp OAuth2 Provider

A new blueprint, `03-headlamp-oidc-provider.yaml`, added to the existing `authentik-blueprints` ConfigMap.

**OAuth2 Provider** (`authentik_providers_oauth2.oauth2provider`):
- `name`: `headlamp`
- `client_type`: `confidential`
- `client_id`: `!Env [HEADLAMP_OIDC_CLIENT_ID]`
- `client_secret`: `!Env [HEADLAMP_OIDC_CLIENT_SECRET]`
- `authorization_flow`: `!Find [authentik_flows.flow, [slug, default-authentication-flow]]`
- `invalidation_flow`: `!Find [authentik_flows.flow, [slug, default-invalidation-flow]]`
- `redirect_uris`: `https://headlamp.catinthehack.ca/oidc-callback`
- `signing_key`: `!Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]`
- `property_mappings`: built-in OpenID scope mappings (openid, profile, email) via `!Find`

**Application** (`authentik_core.application`):
- `slug`: `headlamp`
- `name`: `Headlamp`
- `provider`: `!KeyOf headlamp-provider`
- `meta_launch_url`: `https://headlamp.catinthehack.ca`

### Changes to Existing Files

**`kubernetes/infrastructure/authentik/helmrelease.yaml`** — Add two `global.env` entries:

```yaml
global:
  env:
    - name: AUTHENTIK_ERROR_REPORTING__ENABLED
      value: "false"
    - name: HEADLAMP_OIDC_CLIENT_ID        # new
      valueFrom:
        secretKeyRef:
          name: authentik-secrets
          key: HEADLAMP_OIDC_CLIENT_ID
    - name: HEADLAMP_OIDC_CLIENT_SECRET     # new
      valueFrom:
        secretKeyRef:
          name: authentik-secrets
          key: HEADLAMP_OIDC_CLIENT_SECRET
```

**`kubernetes/infrastructure/authentik/blueprints-configmap.yaml`** — Add `03-headlamp-oidc-provider.yaml` key with the blueprint above.

**`kubernetes/infrastructure/authentik/secret.enc.yaml`** — Add two keys:
- `HEADLAMP_OIDC_CLIENT_ID`
- `HEADLAMP_OIDC_CLIENT_SECRET`

**`kubernetes/apps/headlamp/secret.enc.yaml`** — Replace placeholder values with the same generated credentials.

### Credential Generation

Run once during implementation:

```bash
CLIENT_ID=$(openssl rand -hex 20)
CLIENT_SECRET=$(openssl rand -hex 40)
```

Then edit both SOPS secrets to insert the values. Both secrets use the same age recipient, so the same key decrypts both.

## Out of Scope

- Authentik group or role mapping (Headlamp uses cluster-admin RBAC, no per-user authorization)
- Custom authentication flows (built-in defaults suffice)
- PVC-backed session storage for the outpost (existing ephemeral sessions are acceptable)
