# Headlamp OIDC Blueprint Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automate Headlamp OIDC setup via an Authentik blueprint so no manual UI configuration is needed.

**Architecture:** Generate shared OIDC credentials, store them in two SOPS-encrypted Secrets (Authentik and Headlamp namespaces), expose them to the Authentik worker pod via `global.env` `secretKeyRef`, and reference them in a new blueprint via `!Env`. The blueprint creates the OAuth2 provider and application at boot.

**Tech Stack:** Authentik blueprints, SOPS, Flux HelmRelease, Kustomize

---

### Task 1: Generate OIDC Credentials and Update SOPS Secrets

Two SOPS-encrypted Secrets need real OIDC credentials: `authentik-secrets` (authentik namespace) and `headlamp-oidc` (headlamp namespace). The same client ID and secret must appear in both.

**Important:** The CLAUDE.md rule "NEVER run a command to decrypt secrets" means we must not run `sops decrypt` to view existing secrets. We use `sops set` to add keys to the Authentik secret without decrypting, and recreate the Headlamp secret from scratch (it only contains placeholder values).

**Files:**
- Modify: `kubernetes/infrastructure/authentik/secret.enc.yaml`
- Modify: `kubernetes/apps/headlamp/secret.enc.yaml`

**Step 1: Generate random credentials**

```bash
CLIENT_ID=$(openssl rand -hex 20)
CLIENT_SECRET=$(openssl rand -hex 40)
echo "CLIENT_ID=$CLIENT_ID"
echo "CLIENT_SECRET=$CLIENT_SECRET"
```

Save these values — they go into both secrets.

**Step 2: Add credentials to Authentik secret**

Use `sops set` to add keys without decrypting the entire file:

```bash
cd /Users/cm/Projects/cloudlab/.worktrees/headlamp-oidc
sops set kubernetes/infrastructure/authentik/secret.enc.yaml '["stringData"]["HEADLAMP_OIDC_CLIENT_ID"]' "\"$CLIENT_ID\""
sops set kubernetes/infrastructure/authentik/secret.enc.yaml '["stringData"]["HEADLAMP_OIDC_CLIENT_SECRET"]' "\"$CLIENT_SECRET\""
```

Verify the keys were added (shows encrypted structure, not values):

```bash
grep -c "HEADLAMP_OIDC" kubernetes/infrastructure/authentik/secret.enc.yaml
```

Expected: `2` (two lines matching)

**Step 3: Recreate Headlamp secret with real credentials**

Write the plaintext Secret YAML (no decrypt needed — we overwrite the placeholder file):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-oidc
  namespace: headlamp
type: Opaque
stringData:
  HEADLAMP_CONFIG_OIDC_CLIENT_ID: "<CLIENT_ID value from Step 1>"
  HEADLAMP_CONFIG_OIDC_CLIENT_SECRET: "<CLIENT_SECRET value from Step 1>"
```

Write to disk, then encrypt in-place:

```bash
sops encrypt -i kubernetes/apps/headlamp/secret.enc.yaml
```

Verify:

```bash
grep -c "ENC\[AES256_GCM" kubernetes/apps/headlamp/secret.enc.yaml
```

Expected: several lines with `ENC[AES256_GCM` (all values encrypted)

**Step 4: Run validation**

```bash
mise run check
```

Expected: all checks pass. SOPS-encrypted files are stripped during kustomize+kubeconform.

**Step 5: Commit**

```bash
git add kubernetes/infrastructure/authentik/secret.enc.yaml kubernetes/apps/headlamp/secret.enc.yaml
git commit -m "feat(authentik): add Headlamp OIDC credentials to SOPS secrets"
```

---

### Task 2: Add Blueprint and HelmRelease Environment Variables

Add the OAuth2 provider blueprint to the existing ConfigMap and expose the OIDC credentials as environment variables in the Authentik worker pod.

**Files:**
- Modify: `kubernetes/infrastructure/authentik/blueprints-configmap.yaml`
- Modify: `kubernetes/infrastructure/authentik/helmrelease.yaml`

**Step 1: Add blueprint 03 to ConfigMap**

Open `kubernetes/infrastructure/authentik/blueprints-configmap.yaml`. Add a new key `03-headlamp-oidc-provider.yaml` after the existing `02-proxy-outpost.yaml` entry.

The full ConfigMap after editing:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-blueprints
  namespace: authentik
data:
  01-forward-auth-provider.yaml: |
    # ... existing content unchanged ...

  02-proxy-outpost.yaml: |
    # ... existing content unchanged ...

  03-headlamp-oidc-provider.yaml: |
    version: 1
    metadata:
      name: Headlamp OIDC Provider
    entries:
      - model: authentik_providers_oauth2.oauth2provider
        id: headlamp-provider
        identifiers:
          name: headlamp
        attrs:
          client_type: confidential
          client_id: !Env [HEADLAMP_OIDC_CLIENT_ID]
          client_secret: !Env [HEADLAMP_OIDC_CLIENT_SECRET]
          authorization_flow: !Find [authentik_flows.flow, [slug, default-authentication-flow]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-invalidation-flow]]
          redirect_uris: "https://headlamp.catinthehack.ca/oidc-callback"
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, profile]]
            - !Find [authentik_providers_oauth2.scopemapping, [scope_name, email]]

      - model: authentik_core.application
        identifiers:
          slug: headlamp
        attrs:
          name: Headlamp
          provider: !KeyOf headlamp-provider
          meta_launch_url: "https://headlamp.catinthehack.ca"
```

**Key details:**
- `!Env` reads from the worker pod's environment (set via `global.env` in the next step)
- `!Find` references built-in Authentik objects by database lookup
- `!KeyOf` references the provider created earlier in the same blueprint file
- `property_mappings` uses `authentik_providers_oauth2.scopemapping` (the model name for OAuth2 scope mappings)
- `signing_key` uses the self-signed certificate Authentik generates at install

**Step 2: Add secretKeyRef entries to HelmRelease**

Open `kubernetes/infrastructure/authentik/helmrelease.yaml`. Under `values.global.env`, add two new entries that mount Secret keys as environment variables:

The `global.env` section after editing:

```yaml
    global:
      env:
        - name: AUTHENTIK_ERROR_REPORTING__ENABLED
          value: "false"
        - name: HEADLAMP_OIDC_CLIENT_ID
          valueFrom:
            secretKeyRef:
              name: authentik-secrets
              key: HEADLAMP_OIDC_CLIENT_ID
        - name: HEADLAMP_OIDC_CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: authentik-secrets
              key: HEADLAMP_OIDC_CLIENT_SECRET
```

**Key details:**
- `secretKeyRef.name` is `authentik-secrets` — the same Secret used by `existingSecret.secretName`
- The env var names match what the blueprint's `!Env` references
- Both server and worker pods receive these env vars (chart applies `global.env` to all pods)

**Step 3: Run validation**

```bash
mise run check
```

Expected: all checks pass. The blueprint YAML contains `!Env`, `!Find`, and `!KeyOf` tags — these are Authentik-specific, not standard YAML. Kustomize treats the ConfigMap data value as an opaque string, so these tags pass through without error.

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/authentik/blueprints-configmap.yaml kubernetes/infrastructure/authentik/helmrelease.yaml
git commit -m "feat(authentik): add Headlamp OIDC blueprint and env var injection"
```

---

### Task 3: Update Documentation

Record the new blueprint pattern and OIDC automation in CLAUDE.md.

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add implementation notes**

Add to the `## Implementation Notes` section in `CLAUDE.md`:

```markdown
- **Authentik OIDC blueprint pattern**: For services that support native OIDC, create a blueprint entry with `authentik_providers_oauth2.oauth2provider` model. Store the client ID and secret in the `authentik-secrets` SOPS Secret, expose them via `global.env` `secretKeyRef`, and reference them in the blueprint via `!Env [KEY_NAME]`. This keeps the ConfigMap free of secrets while the public repo remains safe. The same credentials go into the service's own SOPS Secret for injection via Flux `valuesFrom`.
- **Authentik scope mappings model name**: OAuth2 scope mappings use `authentik_providers_oauth2.scopemapping` (not `authentik_providers_oauth2.oauth2scopemapping`). Reference built-in scopes via `!Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]`.
```

Add to the `### Identity and auth` section under `## Deployment Lessons`:

```markdown
- **Use `!Env` for secrets in blueprints, not inline values.** Blueprint ConfigMaps are plaintext and committed to a public repo. Inject credentials through pod environment variables (`global.env` with `secretKeyRef`) and reference them via `!Env [VAR_NAME]` in the blueprint. This keeps the blueprint declarative while the actual credentials stay in SOPS-encrypted Secrets.
- **Reuse `authentik-secrets` for non-Authentik credentials when the worker needs them.** The `global.env` mechanism exposes any Secret key as an environment variable in the worker pod. Adding Headlamp OIDC credentials to `authentik-secrets` avoids creating a cross-namespace Secret reference. The worker reads them via `!Env`; the target service reads them from its own namespace-local Secret.
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add Authentik OIDC blueprint pattern notes"
```

---

## Post-Implementation

After merging, the Authentik worker must restart to pick up the new blueprint and environment variables. Flux handles this automatically when the HelmRelease values change. If the blueprint's `!Find` for built-in objects fails on first apply (race condition with parallel blueprint processing), restart the worker pod:

```bash
kubectl rollout restart deploy/authentik-worker -n authentik
```

Verify the provider was created:

```bash
kubectl exec -n authentik deploy/authentik-worker -- ak list_providers 2>/dev/null || \
  echo "Check the Authentik admin UI at https://auth.catinthehack.ca/admin/#/providers"
```
