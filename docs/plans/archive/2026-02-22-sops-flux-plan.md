# SOPS + Flux — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable Flux's kustomize-controller to decrypt SOPS-encrypted Kubernetes Secrets in-cluster.

**Architecture:** Add a `decryption` block to both Flux Kustomization CRDs referencing a `sops-age` Secret that holds the age private key. A mise task creates this Secret idempotently. A temporary test secret validates the full pipeline: git push, Flux reconcile, in-cluster decryption.

**Tech Stack:** Flux, SOPS, age, Kustomize, Mise

**Design:** `docs/plans/2026-02-22-sops-flux-design.md`

---

### Task 1: Add SOPS decryption to Flux Kustomizations

**Files:**
- Modify: `kubernetes/flux-system/infrastructure.yaml`
- Modify: `kubernetes/flux-system/apps.yaml`

**Step 1: Add decryption block to infrastructure.yaml**

Append a `decryption` block at the end of `spec`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/infrastructure
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
    - name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

**Step 2: Add decryption block to apps.yaml**

Same block, same position:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/apps
  prune: true
  wait: true
  timeout: 5m
  dependsOn:
    - name: infrastructure
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

**Step 3: Validate**

Run: `kustomize build kubernetes/flux-system/ > /dev/null && echo OK`

Expected: `OK`

**Step 4: Commit**

```bash
git add kubernetes/flux-system/infrastructure.yaml kubernetes/flux-system/apps.yaml
git commit -m "feat(flux): add SOPS decryption to Kustomizations"
```

---

### Task 2: Add flux:sops-key mise task

**Files:**
- Modify: `.mise.toml`

**Step 1: Add the task**

Append after `[tasks."talos:upgrade"]`:

```toml
[tasks."flux:sops-key"]
description = "Create or rotate the sops-age Secret in flux-system"
run = """
set -e
if kubectl get secret sops-age -n flux-system >/dev/null 2>&1; then
  kubectl delete secret sops-age -n flux-system
fi
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=.age-key.txt
"""
```

Idempotent: deletes and recreates if the Secret exists, creates fresh otherwise. The key name `age.agekey` matches what kustomize-controller expects.

**Step 2: Verify task appears**

Run: `mise tasks | grep flux:sops-key`

Expected: `flux:sops-key  Create or rotate the sops-age Secret in flux-system`

**Step 3: Commit**

```bash
git add .mise.toml
git commit -m "feat(mise): add flux:sops-key task"
```

---

### Task 3: Create sops-test manifests

**Files:**
- Create: `kubernetes/infrastructure/sops-test/kustomization.yaml`
- Create: `kubernetes/infrastructure/sops-test/secret.enc.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create sops-test directory**

```bash
mkdir -p kubernetes/infrastructure/sops-test
```

**Step 2: Write the Kustomize entry point**

Write `kubernetes/infrastructure/sops-test/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - secret.enc.yaml
```

**Step 3: Write the plaintext Secret**

Write `kubernetes/infrastructure/sops-test/secret.enc.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sops-test
  namespace: default
stringData:
  message: "SOPS decryption works"
```

**Step 4: Add sops-test to infrastructure kustomization**

Update `kubernetes/infrastructure/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - sops-test
```

**Step 5: Validate before encryption**

Run: `kustomize build kubernetes/infrastructure/`

Expected output includes the Secret manifest with `stringData.message: SOPS decryption works`.

**Step 6: Encrypt the Secret**

Run: `sops encrypt -i kubernetes/infrastructure/sops-test/secret.enc.yaml`

The file is replaced with encrypted YAML. The `stringData.message` value becomes an `ENC[AES256_GCM,...]` blob and a `sops` metadata block appears at the bottom. The filename matches the `.sops.yaml` creation rule (`\.enc\.(json|yaml)$`).

**Step 7: Validate after encryption**

Run: `kustomize build kubernetes/infrastructure/ > /dev/null && echo OK`

Expected: `OK` — kustomize processes encrypted YAML without errors.

**Step 8: Commit**

```bash
git add kubernetes/infrastructure/
git commit -m "feat(flux): add sops-test encrypted secret"
```

---

### Task 4: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Step 1: Add flux:sops-key to README Usage section**

Add after the `mise run config:decrypt` line:

```bash
mise run flux:sops-key               # Load age key for SOPS decryption
```

The full block becomes:

```bash
mise run tf init                     # Initialize Terraform
mise run tf plan                     # Preview changes
mise run tf apply                    # Provision and bootstrap
mise run config:export               # Encrypt outputs
mise run config:decrypt              # Decrypt configs for local use
mise run flux:sops-key               # Load age key for SOPS decryption
kubectl get nodes                    # Verify
```

**Step 2: Strikethrough roadmap step 3**

Replace:

```markdown
3. **SOPS + Flux** — Decrypt SOPS-encrypted secrets in-cluster via Flux's kustomize-controller
```

With:

```markdown
3. ~~**SOPS + Flux** — Decrypt SOPS-encrypted secrets in-cluster via Flux's kustomize-controller~~
```

**Step 3: Add flux:sops-key to CLAUDE.md Quick Reference**

Add after the `mise run sops:edit` line:

```bash
mise run flux:sops-key    # Load age key into cluster for SOPS decryption
```

**Step 4: Add implementation note to CLAUDE.md**

Append to the Implementation Notes section (the bulleted list at the bottom):

```markdown
- **SOPS age key in cluster**: The `sops-age` Secret in `flux-system` provides the age private key to kustomize-controller for SOPS decryption. Created via `mise run flux:sops-key` — not managed by Terraform to keep the private key out of state. Re-run after cluster rebuild.
```

**Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: add SOPS workflow to README and CLAUDE.md"
```

---

### Task 5: Deploy and verify (runtime)

> Requires a running cluster with Flux. Not automated in CI.

**Step 1: Push all commits**

```bash
git push
```

**Step 2: Create the sops-age Secret**

Run: `mise run flux:sops-key`

Expected: `secret/sops-age created`

**Step 3: Trigger Flux reconciliation**

Run: `flux reconcile kustomization infrastructure --with-source`

Expected: Flux pulls the latest commit and reconciles. The `sops-test` Secret appears in the `default` namespace.

**Step 4: Verify decryption**

Run: `kubectl get secret sops-test -n default -o jsonpath='{.data.message}' | base64 -d`

Expected: `SOPS decryption works`

---

### Task 6: Remove sops-test after verification

**Files:**
- Delete: `kubernetes/infrastructure/sops-test/` (entire directory)
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Revert infrastructure kustomization**

Update `kubernetes/infrastructure/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

**Step 2: Delete sops-test directory**

```bash
rm -rf kubernetes/infrastructure/sops-test
```

**Step 3: Validate**

Run: `kustomize build kubernetes/infrastructure/ > /dev/null && echo OK`

Expected: `OK`

**Step 4: Commit and push**

```bash
git add kubernetes/infrastructure/
git commit -m "chore(flux): remove sops-test after verification"
git push
```

**Step 5: Verify Flux prunes the Secret**

Run: `flux reconcile kustomization infrastructure --with-source`

Then: `kubectl get secret sops-test -n default`

Expected: `Error from server (NotFound): secrets "sops-test" not found` — Flux pruned it (`prune: true`).
