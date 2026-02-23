# Bootstrap Flux — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Push repo to GitHub, add CI, and bootstrap Flux CD so every future change deploys through git commits.

**Architecture:** Three phases — push the existing repo to GitHub, layer CI and validation tooling (kubeconform, GitHub Actions), then bootstrap Flux into the cluster and add the infrastructure/apps Kustomization hierarchy. Branch protection goes last to avoid blocking direct pushes during setup.

**Tech Stack:** Flux CD, Kustomize, kubeconform, GitHub Actions (mise-action), Mise

**Design:** `docs/plans/2026-02-22-flux-bootstrap-design.md`

---

## Planning Notes

**Discovery: Kustomization file naming.** The design shows Flux Kustomization CRDs at `kubernetes/infrastructure/kustomization.yaml` and `kubernetes/apps/kustomization.yaml`. This conflicts with Kustomize, which treats files named `kustomization.yaml` as its own config. Following the standard Flux pattern (flux2-kustomize-helm-example): Flux CRDs go in `kubernetes/flux-system/` as `infrastructure.yaml` and `apps.yaml`, added to the existing Kustomize `kustomization.yaml`. The `infrastructure/` and `apps/` directories each get a proper Kustomize `kustomization.yaml` with an empty resources list.

**Discovery: Branch protection timing.** The design places branch protection after the initial push, but CI changes and Flux bootstrap both need direct push access to main. Deferring branch protection to the final task avoids this conflict.

**Discovery: `mise run check` scope.** The current `check` task has `dir = "terraform"`. Adding Kubernetes validation requires removing `dir` and using a subshell for terraform commands.

**Discovery: `kustomize` tool.** The design lists `kubeconform` and `flux2` as new tools, but validation also requires standalone `kustomize` for `kustomize build`. Adding it.

**Discovery: kubeconform and Flux CRDs.** Flux custom resources lack schemas in kubeconform's default registry. Using `-ignore-missing-schemas` validates standard resources strictly while skipping unknown CRDs.

**Discovery: README already current.** The roadmap already includes Kyverno, Gitea/Forgejo, Renovate, and Infisical in the correct positions. Only change needed: strike through step 2 as completed.

**Discovery: Branch protection vs single operator.** The design requires PR reviews before merging and includes administrators. For a single-operator repo, requiring 1 approving review makes PRs unmergeable (you cannot approve your own PR). The plan uses `required_approving_review_count: 0` — requiring the PR process and passing CI, but not a second reviewer. Adjust after adding collaborators.

**Testing approach:** No unit test framework for infrastructure code. Validation is `mise run check` after code changes and `flux check` + `kubectl get kustomizations` after bootstrap.

---

### Task 1: Verify security before first push

**Files:** None — read-only verification

**Step 1: Run gitleaks against the full history**

Run: `gitleaks git .`

Expected: "no leaks found". If leaks are found, stop and remediate before proceeding.

**Step 2: Verify .gitignore coverage**

Visually confirm these patterns exist in `.gitignore`:
- `.age-key.txt`
- `terraform/terraform.tfstate`
- `terraform/output/*` with exception `!terraform/output/*.enc.*`
- `.claude/settings.local.json`

Run: `git ls-files --ignored --exclude-standard` to confirm no ignored files are tracked.

**Step 3: Verify SOPS-encrypted files contain only ciphertext**

Run: `grep -L '"sops"' terraform/secrets.enc.json terraform/output/*.enc.yaml 2>/dev/null`

Expected: No output. Every file matching `*.enc.*` contains the `"sops"` metadata key, confirming encryption. If any file appears, it is NOT encrypted — stop and investigate.

---

### Task 2: Create GitHub repo and push

**Files:** None — git operations only

**Step 1: Create the public repo and push**

Run: `gh repo create cloudlab --public --source=. --push`

This creates the remote repo, adds the `origin` remote, and pushes `main` in one command.

**Step 2: Verify**

Run: `gh repo view --web`

Expected: Browser opens showing the repo with all committed files.

---

### Task 3: Add CI and validation tooling

**Files:**
- Modify: `.mise.toml` (add tools, rewrite check task)
- Modify: `lefthook.yml` (add kustomize pre-commit hook)
- Create: `.github/workflows/check.yml`

**Step 1: Look up latest tool versions**

Run:

```bash
mise ls-remote kustomize | tail -1
mise ls-remote kubeconform | tail -1
mise ls-remote flux2 | tail -1
```

Note the latest stable major.minor for each. If `flux2` is not found, try `fluxcd/flux2` or check `mise registry | grep flux`.

**Step 2: Add tools to `.mise.toml`**

Add after the `gitleaks` line in `[tools]`:

```toml
kustomize = "<major.minor>"
kubeconform = "<major.minor>"
flux2 = "<major.minor>"
```

Use the versions from step 1, matching the existing convention (major.minor, e.g., `"5.6"`).

**Step 3: Install the new tools**

Run: `mise install`

Expected: All three tools download and install.

Verify: `kustomize version && kubeconform -v && flux --version`

**Step 4: Rewrite the `check` task in `.mise.toml`**

Replace the entire `[tasks.check]` block with:

```toml
[tasks.check]
description = "Run all linters and validators"
run = """
set -e
echo "==> Terraform"
(cd terraform && terraform fmt -check && terraform validate && tflint)
if [ -d kubernetes ]; then
  echo "==> Kubernetes"
  for dir in kubernetes/*/; do
    if [ -f "${dir}kustomization.yaml" ]; then
      echo "    $dir"
      kustomize build "$dir" | kubeconform -strict -summary -ignore-missing-schemas \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
    fi
  done
fi
echo "==> Gitleaks"
gitleaks git
"""
```

Key changes from the existing task:
- Removed `dir = "terraform"` — uses a subshell `(cd terraform && ...)` instead
- Added Kubernetes validation: builds each subdirectory with kustomize, pipes to kubeconform
- Added `gitleaks detect` for full-repo secret scanning
- Guarded Kubernetes block with `[ -d kubernetes ]` so it passes before Flux bootstrap
- Datree CRDs-catalog as a secondary schema source validates Flux CRDs (Kustomization, HelmRelease, HelmRepository, etc.)
- `-ignore-missing-schemas` remains as a fallback for any CRDs not in the catalog

**Step 5: Update `lefthook.yml`**

Add inside `pre-commit.commands`, after the `lint` block and before `gitleaks`:

```yaml
    kustomize:
      glob: "kubernetes/**/*.yaml"
      run: |
        for dir in kubernetes/*/; do
          if [ -f "${dir}kustomization.yaml" ]; then
            kustomize build "$dir" > /dev/null
          fi
        done
```

Also update the existing `gitleaks` command from the deprecated form:

```yaml
    gitleaks:
      run: gitleaks git --pre-commit --staged
```

The `glob` ensures the hook triggers only when kubernetes YAML files are staged. Output is discarded — only the exit code matters.

**Step 6: Create `.github/workflows/check.yml`**

```yaml
name: Check

on:
  pull_request:
    branches: [main]

permissions:
  contents: read

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

`terraform init -backend=false` downloads providers without configuring state (no credentials needed). `jdx/mise-action@v3` installs mise and all tools from `.mise.toml` with built-in caching.

**Step 7: Validate**

Run: `mise run check`

Expected: Terraform checks pass, no Kubernetes output (directory absent), gitleaks passes.

**Step 8: Commit and push**

```bash
git add .mise.toml lefthook.yml .github/workflows/check.yml
git commit -m "ci: add Kubernetes validation and GitHub Actions workflow"
git push
```

---

### Task 4: Bootstrap Flux

**Files:** Auto-generated — `kubernetes/flux-system/` directory

**Prerequisite:** A running Kubernetes cluster accessible via kubectl.

Run: `kubectl get nodes`

Expected: At least one node in `Ready` state. If not, the cluster needs to be provisioned first (`mise run tf:provision`).

**Step 1: Create a short-lived fine-grained GitHub PAT**

Open: https://github.com/settings/personal-access-tokens/new

Settings:
- **Token name:** Flux bootstrap — cloudlab
- **Expiration:** 1 day
- **Resource owner:** your GitHub account
- **Repository access:** Only select repositories → `cloudlab`
- **Permissions:**
  - **Administration:** Read and write (to create the deploy key)
  - **Contents:** Read and write (to push flux-system manifests)
  - **Metadata:** Read-only (auto-granted)

Copy the token.

**Step 2: Export credentials**

```bash
read -s GITHUB_TOKEN && export GITHUB_TOKEN
export GITHUB_USER=<your-github-username>
```

`read -s` prompts for input without echoing it, keeping the token out of shell history and terminal scrollback.

**Step 3: Run Flux bootstrap**

```bash
flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=cloudlab \
  --branch=main \
  --path=kubernetes/ \
  --personal \
  --private=false
```

Expected output ends with `✔ bootstrap finished`. Flux creates `kubernetes/flux-system/` with three files (gotk-components.yaml, gotk-sync.yaml, kustomization.yaml), pushes them to the repo, installs controllers in the cluster, and registers an SSH deploy key.

**Step 4: Pull the bootstrap commit**

Flux pushed directly to main. Sync your local repo:

```bash
git pull
```

**Step 5: Verify Flux health**

Run: `flux check`

Expected: All components pass — source-controller, kustomize-controller, helm-controller, notification-controller running.

Run: `kubectl get kustomizations -A`

Expected: `flux-system` Kustomization shows `True` / `Ready`.

**Step 6: Verify the check task still passes**

Run: `mise run check`

Expected: Terraform checks pass. Kubernetes checks now validate `kubernetes/flux-system/`. Gitleaks passes.

**Step 7: Delete the PAT and unset variables**

Open https://github.com/settings/tokens and delete the "Flux bootstrap — cloudlab" token.

```bash
unset GITHUB_TOKEN GITHUB_USER
```

---

### Task 5: Add Kustomization hierarchy

**Files:**
- Create: `kubernetes/flux-system/infrastructure.yaml`
- Create: `kubernetes/flux-system/apps.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`
- Create: `kubernetes/infrastructure/kustomization.yaml`
- Create: `kubernetes/apps/kustomization.yaml`

**Step 1: Create the infrastructure Flux Kustomization CRD**

Create `kubernetes/flux-system/infrastructure.yaml`:

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
```

**Step 2: Create the apps Flux Kustomization CRD**

Create `kubernetes/flux-system/apps.yaml`:

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
```

Dependency chain: `flux-system` → `infrastructure` → `apps`.

**Step 3: Add CRDs to flux-system Kustomize resources**

Edit `kubernetes/flux-system/kustomization.yaml`. Add `infrastructure.yaml` and `apps.yaml` to the `resources` list. After editing, the resources section should read:

```yaml
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
  - infrastructure.yaml
  - apps.yaml
```

Do NOT modify `apiVersion` or `kind` — only add the two lines.

**Step 4: Create the infrastructure directory**

Create `kubernetes/infrastructure/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

Future steps (ingress, cert-manager, monitoring, etc.) add subdirectories here and list them in `resources`.

**Step 5: Create the apps directory**

Create `kubernetes/apps/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

**Step 6: Validate**

Run: `mise run check`

Expected: All checks pass. Kubernetes section validates flux-system, infrastructure, and apps directories.

Run: `kustomize build kubernetes/flux-system/`

Expected: Output includes the gotk-components, gotk-sync, infrastructure Kustomization CRD, and apps Kustomization CRD.

**Step 7: Commit and push**

```bash
git add kubernetes/flux-system/infrastructure.yaml kubernetes/flux-system/apps.yaml kubernetes/flux-system/kustomization.yaml kubernetes/infrastructure/ kubernetes/apps/
git commit -m "feat(flux): add infrastructure and apps Kustomization hierarchy"
git push
```

**Step 8: Verify Flux reconciliation**

Force reconciliation (otherwise wait up to 10 minutes):

```bash
flux reconcile kustomization flux-system --with-source
```

Run: `kubectl get kustomizations -A`

Expected: Three Kustomizations — `flux-system`, `infrastructure`, `apps` — all showing `True` / `Ready`.

---

### Task 6: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Step 1: Strike through step 2 in README.md roadmap**

Change:

```markdown
2. **Bootstrap Flux** — GitHub repo, CI, GitOps foundation
```

to:

```markdown
2. ~~**Bootstrap Flux** — GitHub repo, CI, GitOps foundation~~
```

**Step 2: Add operational notes to README.md**

Add a new section after "Architecture" and before "Tools":

```markdown
## Operations

**Re-bootstrap Flux after cluster rebuild:** `flux bootstrap github` is idempotent. If the cluster is reprovisioned (`mise run tf apply`), re-run the bootstrap command to reinstall Flux controllers. The existing deploy key and repo configuration are reused.

**Rotate the Flux deploy key:** The SSH deploy key registered during bootstrap has no expiry. To rotate it, delete the existing deploy key in GitHub repo settings, then re-run `flux bootstrap github` with a new fine-grained PAT.
```

**Step 3: Update CLAUDE.md — Quick Reference**

Replace the `mise run check` line in the Quick Reference block:

```bash
mise run check            # Run all validators: tf fmt, validate, lint, kustomize, kubeconform, gitleaks
```

**Step 4: Update CLAUDE.md — Repository Structure**

Add after the `docs/plans/` bullet:

```markdown
- **`kubernetes/`** — Flux GitOps manifests (Kustomization hierarchy)
- **`.github/workflows/`** — GitHub Actions CI
```

**Step 5: Update CLAUDE.md — Key Files table**

Add these rows:

| File | Purpose |
|------|---------|
| `.github/workflows/check.yml` | GitHub Actions CI — runs `mise run check` on PRs |
| `kubernetes/flux-system/` | Auto-generated Flux controllers and sync config |
| `kubernetes/flux-system/infrastructure.yaml` | Flux Kustomization CRD — reconciles `kubernetes/infrastructure/` |
| `kubernetes/flux-system/apps.yaml` | Flux Kustomization CRD — reconciles `kubernetes/apps/` |
| `kubernetes/infrastructure/kustomization.yaml` | Kustomize entry point for cluster services (empty until step 3+) |
| `kubernetes/apps/kustomization.yaml` | Kustomize entry point for workloads (empty until step 14+) |

**Step 6: Update CLAUDE.md — Validation section**

Replace the Validation section (both the code block and the paragraph below it) with:

```markdown
## Validation

```bash
mise run check            # Full suite: tf fmt, validate, lint, kustomize, kubeconform, gitleaks
mise run tf plan          # Verify Terraform changes before applying
flux check                # Verify Flux controllers are healthy
flux reconcile kustomization flux-system --with-source  # Force reconciliation
```

Three validation contexts: lefthook runs a fast subset on pre-commit (terraform fmt, kustomize build, gitleaks). `mise run check` runs the full suite on demand. GitHub Actions runs `mise run check` on every PR and gates merge.
```

**Step 7: Update CLAUDE.md — add Implementation Notes**

Add to the Implementation Notes section:

```markdown
- **Flux Kustomization hierarchy**: Flux CRDs (`infrastructure.yaml`, `apps.yaml`) live in `kubernetes/flux-system/` and are listed in its Kustomize `kustomization.yaml`. Target directories (`infrastructure/`, `apps/`) have their own Kustomize `kustomization.yaml` with resource lists. This avoids the naming conflict between Flux Kustomization CRDs and Kustomize's `kustomization.yaml`.
- **`mise run check` scope**: The `check` task runs from the project root (not `dir = "terraform"`). Terraform commands run in a subshell. Kubernetes validation is guarded by `[ -d kubernetes ]` and skips if the directory doesn't exist.
```

**Step 8: Validate**

Run: `mise run check`

Expected: All checks pass (documentation changes don't affect validation).

**Step 9: Commit and push**

```bash
git add README.md CLAUDE.md
git commit -m "docs: update roadmap and project docs for Flux bootstrap"
git push
```

---

### Task 7: Configure branch protection

**Files:** None — GitHub API operations only

**Step 1: Get the repo identifier**

Run: `REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) && echo $REPO`

Expected: `<username>/cloudlab`

**Step 2: Enable branch protection**

```bash
gh api "repos/$REPO/branches/main/protection" \
  --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["check"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

- `required_status_checks.contexts: ["check"]` — the CI job must pass before merge
- `strict: true` — branch must be up to date before merge
- `enforce_admins: true` — rules apply to repository administrators
- `required_approving_review_count: 0` — PRs required, but no reviewer needed (practical for single-operator; increase to 1 when adding collaborators)
- `allow_force_pushes: false` — blocks force pushes to main

**Step 3: Verify protection**

Run: `gh api "repos/$REPO/branches/main/protection" --jq '{status_checks: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled, force_push: .allow_force_pushes.enabled}'`

Expected:

```json
{
  "status_checks": ["check"],
  "enforce_admins": true,
  "force_push": false
}
```

**Step 4: Test the full PR workflow**

```bash
git checkout -b test/verify-ci
```

Make a trivial change (e.g., add a blank line to README.md), commit, and push:

```bash
echo "" >> README.md
git add README.md
git commit -m "test: verify CI and branch protection"
git push -u origin test/verify-ci
```

Open a PR and watch CI:

```bash
gh pr create --title "test: verify CI and branch protection" --body "Testing. Close after CI passes."
gh pr checks test/verify-ci --watch
```

Expected: The `check` job passes.

Clean up:

```bash
gh pr close test/verify-ci --delete-branch
git checkout main
git branch -D test/verify-ci
```

If the status check name doesn't match `check`, update branch protection:

```bash
gh api "repos/$REPO/branches/main/protection/required_status_checks" \
  --method PATCH \
  --input - <<'EOF'
{
  "strict": true,
  "contexts": ["<correct-check-name>"]
}
EOF
```
