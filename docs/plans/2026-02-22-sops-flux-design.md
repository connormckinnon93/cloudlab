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
  --from-file=age.agekey=.age-key.txt
```

The key name `age.agekey` matches what kustomize-controller expects by default.

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

### 3. Test secret

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

### 4. Mise task

Add `flux:sops-key` — an idempotent wrapper that checks whether the `sops-age` Secret exists, deletes and recreates it if so, or creates it fresh.

### 5. Documentation

- **README.md**: Add `mise run flux:sops-key` to the workflow section, between setup and `tf apply`. Strikethrough step 3 in the roadmap.
- **CLAUDE.md**: Add implementation note about the `sops-age` Secret convention and the manual bootstrap step.

### 6. Validation

No changes to `lefthook.yml` or `mise run check`. Existing kustomize build and kubeconform hooks already cover new manifests under `kubernetes/infrastructure/`.

## Decisions

| Decision | Choice | Reasoning |
|----------|--------|-----------|
| Age key provisioning | Manual `kubectl` | Keeps private key out of Terraform state |
| Secret namespace | `flux-system` | Default for kustomize-controller; no cross-namespace config needed |
| Decryption scope | Both `infrastructure` and `apps` | Costs nothing; prevents future misconfiguration |
| Test secret | Include, then remove | Validates pipeline before step 4 depends on it |

## Out of Scope

- SOPS-encrypted HelmRelease values (introduced when specific charts need credentials, starting at step 4)
- Age key rotation procedure (document when the need arises)
- Multi-key or multi-recipient SOPS setup (single operator, single key suffices)
