# SOPS + Flux — Design

## Goal

Enable Flux's kustomize-controller to decrypt SOPS-encrypted Kubernetes Secrets in-cluster, so that all subsequent roadmap steps can manage credentials through git.

## Prerequisites

- Flux bootstrapped and reconciling (step 2, complete)
- Age keypair generated (`.age-key.txt` exists locally)
- `kubectl` access to the cluster

## Changes

### 1. Age private key as a Kubernetes Secret

Create a `sops-age` Secret in the `flux-system` namespace via `kubectl`. This is a manual, one-time operation — re-run only when recreating the cluster or rotating the age key.

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=identity.agekey=.age-key.txt
```

The key name `identity.agekey` ends with the `.agekey` suffix that kustomize-controller uses to identify age private keys within the referenced Secret. This matches the naming convention from Flux's documentation.

**Why manual, not Terraform:** The Kubernetes provider stores secret data in Terraform state as plaintext. A manual `kubectl` command avoids this exposure entirely. The age key rarely changes, so automation provides little benefit.

### 2. Flux Kustomization decryption blocks

Add a `decryption` block to both `infrastructure.yaml` and `apps.yaml`:

```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

kustomize-controller looks up `sops-age` in its own namespace (`flux-system`) and uses the age key to decrypt any SOPS-encrypted values in manifests under each Kustomization's path. No changes to `gotk-sync.yaml` or `gotk-components.yaml` — kustomize-controller has built-in SOPS support.

Both Kustomizations get decryption from the start. This avoids a future debugging session when `apps` first needs a secret.

### 3. SOPS creation rules for Kubernetes manifests

Add a Kubernetes-specific creation rule to `.sops.yaml` with `encrypted_regex` so that only `data` and `stringData` values are encrypted. This preserves the manifest structure (`apiVersion`, `kind`, `metadata`) that `kustomize build` needs to parse the file.

The new rule must come before the existing catch-all because SOPS uses first-match semantics:

```yaml
creation_rules:
  - path_regex: 'kubernetes/.*\.enc\.(json|yaml)$'
    encrypted_regex: '^(data|stringData)$'
    age: "age1..."
  - path_regex: '\.enc\.(json|yaml)$'
    age: "age1..."
```

Without `encrypted_regex`, SOPS encrypts the entire file — `kustomize build` cannot identify the resource type and fails, breaking both lefthook and `mise run check`.

### 4. Test secret

Deploy a SOPS-encrypted Secret to verify the full pipeline: git commit, Flux reconcile, in-cluster decryption.

Directory structure:

```
kubernetes/infrastructure/
  sops-test/
    secret.enc.yaml
    kustomization.yaml
  kustomization.yaml          # Add sops-test to resources
```

The Secret before encryption:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sops-test
  namespace: default
stringData:
  message: "SOPS decryption works"
```

Encrypt with `sops encrypt`, commit, push. Flux decrypts and creates the Secret. Verify:

```bash
kubectl get secret sops-test -n default -o jsonpath='{.data.message}' | base64 -d
```

After verification, remove `sops-test/` from the infrastructure kustomization, commit, push. Flux prunes it automatically (`prune: true`).

### 5. Mise task

Add `flux:sops-key` — an idempotent task that creates or updates the `sops-age` Secret using the standard `dry-run=client | apply` pattern:

```toml
[tasks."flux:sops-key"]
description = "Create or update the sops-age Secret in flux-system"
run = """
set -e
if [ ! -f .age-key.txt ]; then
  echo "Error: .age-key.txt not found" >&2
  exit 1
fi
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=identity.agekey=.age-key.txt \
  --dry-run=client -o yaml | kubectl apply -f -
echo "sops-age Secret applied in flux-system"
"""
```

This is a single atomic operation — no deletion window, no conditional logic, fully idempotent.

### 6. Documentation

- **README.md**: Add `mise run flux:sops-key` to the workflow section, after `config:decrypt` and Flux bootstrap. Strikethrough step 3 in the roadmap.
- **CLAUDE.md**:
  - Add `mise run flux:sops-key` to the quick reference section.
  - Add implementation note about the `sops-age` Secret convention: kustomize-controller identifies age keys by the `.agekey` suffix on Secret data keys.
  - Add implementation note about the Flux Kustomization `decryption` block convention: all Flux Kustomization CRDs (`infrastructure.yaml`, `apps.yaml`, and any future additions) include a `decryption` block referencing `sops-age` from the start.

### 7. Validation

Add `-skip Secret` to the kubeconform invocation in `mise run check`. SOPS appends a top-level `sops:` metadata block to encrypted manifests; `kubeconform -strict` rejects this as an unknown property. Skipping Secret validation is the standard workaround — Secrets have a trivial schema that rarely benefits from strict validation.

No changes to `lefthook.yml` — the lefthook `kustomize` hook runs `kustomize build` only (no kubeconform), and `kustomize build` is lenient about extra fields.

## Decisions

| Decision | Choice | Reasoning |
|----------|--------|-----------|
| Age key provisioning | Manual `kubectl` | Keeps private key out of Terraform state |
| Secret namespace | `flux-system` | Default for kustomize-controller; no cross-namespace config needed |
| Secret data key name | `identity.agekey` | Matches Flux documentation convention; `.agekey` suffix is what the controller matches on |
| Decryption scope | Both `infrastructure` and `apps` | Costs nothing; prevents future misconfiguration |
| SOPS `encrypted_regex` | `^(data|stringData)$` for Kubernetes | Preserves manifest structure for `kustomize build` |
| Mise task idempotency | `dry-run=client \| apply` | Atomic create-or-update; no deletion window |
| kubeconform Secrets | `-skip Secret` | SOPS metadata block is incompatible with `-strict`; Secrets have trivial schema |
| Test secret | Include, then remove | Validates pipeline before step 4 depends on it |

## Out of Scope

- SOPS-encrypted HelmRelease values (introduced when specific charts need credentials, starting at step 4)
- Age key rotation procedure (document when the need arises)
- Multi-key or multi-recipient SOPS setup (single operator, single key suffices)
