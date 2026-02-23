# Systematic Codebase Review — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Review and test the entire cloudlab codebase using TDD, one component at a time.

**Architecture:** Each review item follows red-green-refactor. Write a test that defines expected behavior, observe failures, fix issues, then refactor. Validate statically with `mise run check` and manually against the live cluster.

**Tech Stack:** Bash test scripts, Terraform test files (`.tftest.hcl`), `tflint`, `kubeconform`, `kustomize`, `mise`

---

## Conventions

- **Test script location:** `tests/` directory at the project root
- **Test runner:** `mise run test` (new task, created in Task 1)
- **Commit pattern:** One commit per red-green-refactor cycle
- **Branch:** Feature branch `refactor/systematic-review`
- **Live verification:** Commands listed as `LIVE:` — run manually and report results

---

## Phase 0 — Housekeeping

### Task 1: Create the test infrastructure

Set up the `tests/` directory and `mise run test` task so all subsequent review items have a place to put assertions.

**Files:**
- Create: `tests/run-all.sh`
- Modify: `.mise.toml:34` (add `test` task before `check`)

**Step 1: Write the test runner script**

Create `tests/run-all.sh` — an empty runner that exits 0 when no tests fail:

```bash
#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

for test_file in "$TESTS_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  name="$(basename "$test_file" .sh)"
  if bash "$test_file"; then
    echo "  PASS  $name"
    ((PASS++))
  else
    echo "  FAIL  $name"
    ((FAIL++))
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

**Step 2: Add `mise run test` task**

Add to `.mise.toml` after the `[tasks.check]` block (after line 54):

```toml
[tasks.test]
description = "Run project tests"
run = "bash tests/run-all.sh"
```

**Step 3: Add test invocation to `mise run check`**

Append `mise run test` as the last line of the `check` task's `run` block, so all tests run as part of the full validation suite.

**Step 4: Run to verify the runner works with no tests**

Run: `mise run test`
Expected: `Results: 0 passed, 0 failed` and exit 0.

**Step 5: Commit**

```bash
git add tests/run-all.sh .mise.toml
git commit -m "test: add test runner infrastructure for systematic review"
```

---

### Task 2: Documentation accuracy (Phase 0.1)

Verify that documentation references match actual files and directories.

**Files:**
- Create: `tests/test-docs-accuracy.sh`
- Review: `CLAUDE.md`, `ARCHITECTURE.md`, `README.md`

**Step 1: Write the failing test**

Create `tests/test-docs-accuracy.sh` that extracts file/directory references from documentation and verifies they exist:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

check_path() {
  local doc="$1" path="$2"
  if [ ! -e "$ROOT/$path" ]; then
    echo "  $doc references missing path: $path"
    ((ERRORS++))
  fi
}

# Key files referenced in CLAUDE.md
check_path "CLAUDE.md" ".mise.toml"
check_path "CLAUDE.md" ".sops.yaml"
check_path "CLAUDE.md" "terraform/versions.tf"
check_path "CLAUDE.md" "terraform/variables.tf"
check_path "CLAUDE.md" "terraform/config.auto.tfvars"
check_path "CLAUDE.md" "terraform/main.tf"
check_path "CLAUDE.md" "terraform/talos.tf"
check_path "CLAUDE.md" "terraform/outputs.tf"
check_path "CLAUDE.md" "terraform/secrets.enc.json"
check_path "CLAUDE.md" "terraform/.tflint.hcl"
check_path "CLAUDE.md" "lefthook.yml"
check_path "CLAUDE.md" ".github/workflows/check.yml"
check_path "CLAUDE.md" "kubernetes/kustomization.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/"
check_path "CLAUDE.md" "kubernetes/infrastructure/"
check_path "CLAUDE.md" "kubernetes/infrastructure-config/"
check_path "CLAUDE.md" "kubernetes/cluster-policies/"
check_path "CLAUDE.md" "kubernetes/apps/"
check_path "CLAUDE.md" "kubernetes/apps/whoami/"
check_path "CLAUDE.md" "kubernetes/infrastructure/nfs-provisioner/"
check_path "CLAUDE.md" "kubernetes/infrastructure/kyverno/"
check_path "CLAUDE.md" "kubernetes/infrastructure/gateway-api/"
check_path "CLAUDE.md" "kubernetes/infrastructure/cert-manager/"
check_path "CLAUDE.md" "kubernetes/infrastructure/traefik/"
check_path "CLAUDE.md" "kubernetes/infrastructure/adguard/"
check_path "CLAUDE.md" "kubernetes/infrastructure/monitoring/"
check_path "CLAUDE.md" "kubernetes/infrastructure/cloudnative-pg/"
check_path "CLAUDE.md" "kubernetes/infrastructure/postgres/"
check_path "CLAUDE.md" "kubernetes/infrastructure/authentik/"
check_path "CLAUDE.md" "kubernetes/cluster-policies/clusterpolicy-inject-forward-auth.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/infrastructure.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/infrastructure-config.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/cluster-policies.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/apps.yaml"

# Key files referenced in ARCHITECTURE.md
check_path "ARCHITECTURE.md" "kubernetes/apps/kustomization.yaml"

# Verify ARCHITECTURE.md lists all infrastructure components
for dir in "$ROOT"/kubernetes/infrastructure/*/; do
  component="$(basename "$dir")"
  if ! grep -q "$component" "$ROOT/ARCHITECTURE.md"; then
    echo "  ARCHITECTURE.md missing infrastructure component: $component"
    ((ERRORS++))
  fi
done

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run to see what fails**

Run: `mise run test`
Expected: Some references may be stale. Note which ones.

**Step 3: Fix documentation to match reality**

Update `CLAUDE.md`, `ARCHITECTURE.md`, and `README.md` to match the actual codebase. Remove stale references. Add missing components.

**Step 4: Run tests to verify fixes**

Run: `mise run test`
Expected: PASS

**Step 5: Commit**

```bash
git add tests/test-docs-accuracy.sh CLAUDE.md ARCHITECTURE.md README.md
git commit -m "docs: fix stale references found by documentation accuracy test"
```

---

### Task 3: Tool version audit (Phase 0.2)

Check `.mise.toml` tool versions for available updates.

**Files:**
- Review: `.mise.toml:1-13`

**Step 1: Check for outdated tools**

Run: `mise outdated`
Expected: List of tools with available updates.

**Step 2: Evaluate each update**

For each outdated tool, check release notes for:
- Security fixes (update immediately)
- Breaking changes (evaluate before updating)
- Minor patches (update)

**Step 3: Update tool versions in `.mise.toml`**

Edit `.mise.toml` lines 1-13 with updated versions.

**Step 4: Verify tools install and work**

Run: `mise install && mise run check`
Expected: All tools install; full check suite passes.

**Step 5: Commit**

```bash
git add .mise.toml
git commit -m "build: update tool versions in mise"
```

---

### Task 4: Encryption and secret scanning config (Phase 0.3)

Verify SOPS creation rules cover all encrypted files and gitleaks rules are sufficient.

**Files:**
- Create: `tests/test-sops-coverage.sh`
- Review: `.sops.yaml`, `.gitleaks.toml`

**Step 1: Write the failing test**

Create `tests/test-sops-coverage.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

# Every .enc. file must be SOPS-encrypted (has a "sops" key)
while IFS= read -r -d '' file; do
  case "$file" in
    *.enc.json)
      if ! grep -q '"sops"' "$file"; then
        echo "  Not SOPS-encrypted: $file"
        ((ERRORS++))
      fi
      ;;
    *.enc.yaml)
      if ! grep -q '^sops:' "$file"; then
        echo "  Not SOPS-encrypted: $file"
        ((ERRORS++))
      fi
      ;;
  esac
done < <(find "$ROOT" -name '*.enc.*' -print0)

# Verify .sops.yaml path_regex matches the .enc. naming convention
if ! grep -q 'path_regex.*\\.enc\\.' "$ROOT/.sops.yaml"; then
  echo "  .sops.yaml missing .enc. path_regex pattern"
  ((ERRORS++))
fi

# Verify gitleaks config extends defaults
if ! grep -q 'useDefault = true' "$ROOT/.gitleaks.toml"; then
  echo "  .gitleaks.toml must extend default rules"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run to see what fails**

Run: `mise run test`
Expected: PASS if all encrypted files are well-formed; note any failures.

**Step 3: Fix any issues found**

If any `.enc.` file is not actually encrypted, encrypt it with `sops encrypt -i <file>`.

**Step 4: Run full validation**

Run: `mise run check`
Expected: PASS, including `gitleaks git` clean.

**Step 5: Commit**

```bash
git add tests/test-sops-coverage.sh .sops.yaml .gitleaks.toml
git commit -m "test: add SOPS coverage and gitleaks config validation"
```

---

## Phase 1 — Validation Pipeline

### Task 5: Review mise tasks (Phase 1.1)

Verify all 13 mise tasks run correctly and the `check` task catches bad input.

**Files:**
- Create: `tests/test-check-catches-bad-tf.sh`
- Create: `tests/test-check-catches-bad-yaml.sh`
- Review: `.mise.toml:20-119`

**Step 1: Write test for bad Terraform detection**

Create `tests/test-check-catches-bad-tf.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Create intentionally malformed Terraform file
BAD_FILE="$ROOT/terraform/_test_bad.tf"
echo 'resource "null" "bad" {' > "$BAD_FILE"
trap 'rm -f "$BAD_FILE"' EXIT

# The check task should fail on malformed Terraform
if (cd "$ROOT/terraform" && terraform validate 2>/dev/null); then
  echo "  terraform validate should have failed on malformed .tf file"
  exit 1
fi
```

**Step 2: Write test for bad YAML detection**

Create `tests/test-check-catches-bad-yaml.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Create a temporary Kustomize directory with invalid YAML
BAD_DIR="$ROOT/kubernetes/_test_bad"
mkdir -p "$BAD_DIR"
cat > "$BAD_DIR/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - bad.yaml
EOF
echo "not: valid: kubernetes: resource" > "$BAD_DIR/bad.yaml"
trap 'rm -rf "$BAD_DIR"' EXIT

# kustomize build should fail or kubeconform should reject it
if kustomize build "$BAD_DIR" 2>/dev/null | kubeconform -strict -summary 2>/dev/null; then
  echo "  kubeconform should have rejected invalid Kubernetes YAML"
  exit 1
fi
```

**Step 3: Run tests**

Run: `mise run test`
Expected: Both tests PASS (bad input is caught).

**Step 4: Review each mise task for correctness**

Read `.mise.toml:20-119` and verify:
- `setup`: installs all tools, initializes terraform and tflint, installs lefthook
- `tf`: passes arbitrary subcommands correctly
- `check`: runs terraform fmt/validate/lint, kustomize+kubeconform, gitleaks
- `config:export` / `config:decrypt`: handle the encrypt/decrypt round-trip
- `sops:edit`: opens the right file
- `talos:upgrade`: passes schematic and version correctly
- `flux:sops-key`: creates/rotates the secret

Fix any issues found (missing error handling, incorrect paths, etc.).

**Step 5: Commit**

```bash
git add tests/test-check-catches-bad-tf.sh tests/test-check-catches-bad-yaml.sh .mise.toml
git commit -m "test: verify check task catches malformed Terraform and YAML"
```

---

### Task 6: Review lefthook hooks (Phase 1.2)

Verify hook coverage matches `mise run check` and hooks run fast.

**Files:**
- Create: `tests/test-hook-check-parity.sh`
- Review: `lefthook.yml`

**Step 1: Write parity test**

Create `tests/test-hook-check-parity.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

# lefthook pre-commit must include these validators (same as mise run check)
LEFTHOOK="$ROOT/lefthook.yml"

for check in "terraform fmt" "terraform validate" "tflint" "kustomize" "gitleaks"; do
  if ! grep -q "$check" "$LEFTHOOK"; then
    echo "  lefthook.yml missing pre-commit check: $check"
    ((ERRORS++))
  fi
done

# Verify commit-msg hook enforces conventional commits
if ! grep -q "conventional" "$LEFTHOOK"; then
  echo "  lefthook.yml missing conventional commit enforcement"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS.

**Step 3: Compare lefthook and check task coverage**

The `check` task runs kubeconform validation that lefthook's `kustomize` hook skips (lefthook only runs `kustomize build > /dev/null`). This is intentional — kubeconform fetches remote schemas and is too slow for pre-commit. Verify this trade-off is still acceptable.

**Step 4: Commit**

```bash
git add tests/test-hook-check-parity.sh lefthook.yml
git commit -m "test: verify lefthook hook coverage matches check task"
```

---

### Task 7: Review GitHub Actions CI (Phase 1.3)

Verify CI runs the same validations as local `mise run check`.

**Files:**
- Create: `tests/test-ci-parity.sh`
- Review: `.github/workflows/check.yml`

**Step 1: Write CI parity test**

Create `tests/test-ci-parity.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

CI_FILE="$ROOT/.github/workflows/check.yml"

# CI must run mise run check
if ! grep -q "mise run check" "$CI_FILE"; then
  echo "  CI workflow does not run 'mise run check'"
  ((ERRORS++))
fi

# CI must initialize terraform providers (required for validate)
if ! grep -q "terraform init" "$CI_FILE"; then
  echo "  CI workflow does not initialize Terraform"
  ((ERRORS++))
fi

# CI must initialize tflint plugins
if ! grep -q "tflint --init" "$CI_FILE"; then
  echo "  CI workflow does not initialize tflint plugins"
  ((ERRORS++))
fi

# CI triggers on PRs to main
if ! grep -q "pull_request" "$CI_FILE"; then
  echo "  CI workflow does not trigger on pull_request"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS.

**Step 3: Review CI for improvements**

Check `.github/workflows/check.yml` for:
- Action versions pinned to commit SHAs (already done: `actions/checkout@de0fac2e`, `jdx/mise-action@6d1e696a`)
- Caching (mise-action handles tool caching)
- Whether `mise run test` should also run in CI (yes — add it to the check task)

**Step 4: Commit any fixes**

```bash
git add tests/test-ci-parity.sh .github/workflows/check.yml
git commit -m "test: verify CI parity with local check task"
```

**LIVE:** Push the branch and verify CI passes: `gh pr checks <number> --watch`

---

## Phase 2 — Terraform

### Task 8: Review versions.tf and variables.tf (Phase 2.1)

Verify provider constraints and variable validation rules.

**Files:**
- Create: `tests/test-terraform-variables.sh`
- Review: `terraform/versions.tf:1-18`
- Review: `terraform/variables.tf:1-118`

**Step 1: Write variable validation test**

Create `tests/test-terraform-variables.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

VARS_FILE="$ROOT/terraform/variables.tf"

# Every variable must have a description
VAR_COUNT=$(grep -c '^variable ' "$VARS_FILE")
DESC_COUNT=$(grep -c 'description' "$VARS_FILE")
if [ "$VAR_COUNT" -ne "$DESC_COUNT" ]; then
  echo "  Not all variables have descriptions ($VAR_COUNT vars, $DESC_COUNT descriptions)"
  ((ERRORS++))
fi

# Variables with IP addresses must have validation blocks
for var in talos_node_ip gateway; do
  if ! awk "/^variable \"$var\"/,/^}/" "$VARS_FILE" | grep -q 'validation'; then
    echo "  Variable '$var' missing validation block"
    ((ERRORS++))
  fi
done

# Provider versions must use pessimistic constraint (~>)
VERSIONS_FILE="$ROOT/terraform/versions.tf"
PROVIDER_COUNT=$(grep -c 'version.*=' "$VERSIONS_FILE")
PESSIMISTIC_COUNT=$(grep -c '~>' "$VERSIONS_FILE")
if [ "$PROVIDER_COUNT" -ne "$PESSIMISTIC_COUNT" ]; then
  echo "  Not all provider versions use pessimistic constraints (~>)"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS if all variables are well-defined.

**Step 3: Review variable validation completeness**

Check each variable's validation regex:
- `proxmox_endpoint` (`terraform/variables.tf:6`): Only checks `^https://` — consider validating URL format more strictly
- `talos_node_ip` (`terraform/variables.tf:28`): Regex allows octets >255 (e.g., `999.999.999.999`) — tighten if desired
- `gateway` (`terraform/variables.tf:37`): Same regex issue as `talos_node_ip`
- `proxmox_ssh_username` (`terraform/variables.tf:11-15`): No validation — add non-empty check
- `proxmox_node_name` (`terraform/variables.tf:17-21`): No validation — add non-empty check

Fix issues found. Run `mise run tf validate` after each change.

**Step 4: Commit**

```bash
git add tests/test-terraform-variables.sh terraform/variables.tf terraform/versions.tf
git commit -m "test: add variable validation checks for Terraform"
```

**LIVE:** `mise run tf plan` — expect no changes.

---

### Task 9: Review main.tf (Phase 2.2)

Review Proxmox provider and VM resource configuration.

**Files:**
- Create: `tests/test-terraform-resources.sh`
- Review: `terraform/main.tf:1-99`

**Step 1: Write resource structure test**

Create `tests/test-terraform-resources.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

MAIN_FILE="$ROOT/terraform/main.tf"

# VM resource must exist
if ! grep -q 'resource "proxmox_virtual_environment_vm"' "$MAIN_FILE"; then
  echo "  Missing VM resource definition"
  ((ERRORS++))
fi

# VM must have QEMU guest agent enabled (required for IP discovery)
if ! grep -q 'agent' "$MAIN_FILE" || ! grep -q 'enabled = true' "$MAIN_FILE"; then
  echo "  VM must have QEMU guest agent enabled"
  ((ERRORS++))
fi

# VM must have TPM state (required for LUKS2 encryption)
if ! grep -q 'tpm_state' "$MAIN_FILE"; then
  echo "  VM must have TPM state for disk encryption"
  ((ERRORS++))
fi

# VM must have EFI disk (required for SecureBoot)
if ! grep -q 'efi_disk' "$MAIN_FILE"; then
  echo "  VM must have EFI disk for SecureBoot"
  ((ERRORS++))
fi

# VM must use lifecycle ignore_changes for cdrom (prevents recreation on image update)
if ! grep -q 'ignore_changes.*cdrom' "$MAIN_FILE"; then
  echo "  VM must ignore cdrom changes in lifecycle"
  ((ERRORS++))
fi

# No hardcoded IPs in main.tf (should all be variables)
if grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$MAIN_FILE"; then
  echo "  main.tf contains hardcoded IP addresses — use variables"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS.

**Step 3: Review for hardcoded values and missing configuration**

Check `terraform/main.tf` for:
- `datastore_id = "local-lvm"` (lines 62, 68, 73) — consider making this a variable
- `bridge = "vmbr0"` (line 87) — consider making this a variable
- `insecure = true` (line 15) — appropriate for homelab, document the reason
- `stop_on_destroy = true` (line 46) — correct for single-node

Refactor hardcoded values to variables where it improves reusability without over-engineering.

**Step 4: Commit**

```bash
git add tests/test-terraform-resources.sh terraform/main.tf terraform/variables.tf
git commit -m "test: add Terraform resource structure validation"
```

**LIVE:** `mise run tf plan` — expect no changes (or only variable default additions).

---

### Task 10: Review talos.tf (Phase 2.3)

Review TalosOS machine configuration and bootstrap ordering.

**Files:**
- Create: `tests/test-terraform-talos.sh`
- Review: `terraform/talos.tf:1-137`

**Step 1: Write Talos configuration test**

Create `tests/test-terraform-talos.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

TALOS_FILE="$ROOT/terraform/talos.tf"

# Must have machine secrets resource
if ! grep -q 'resource "talos_machine_secrets"' "$TALOS_FILE"; then
  echo "  Missing talos_machine_secrets resource"
  ((ERRORS++))
fi

# Config apply must use local.vm_ip (DHCP address), not var.talos_node_ip
if grep -q 'node.*=.*var\.talos_node_ip' "$TALOS_FILE" | head -1 && \
   grep -q 'talos_machine_configuration_apply' "$TALOS_FILE"; then
  # Check specifically in the apply resource
  APPLY_NODE=$(awk '/resource "talos_machine_configuration_apply"/,/^}/' "$TALOS_FILE" | grep 'node ')
  if echo "$APPLY_NODE" | grep -q 'var.talos_node_ip'; then
    echo "  Config apply must use local.vm_ip (DHCP), not var.talos_node_ip (static)"
    ((ERRORS++))
  fi
fi

# Bootstrap must depend on config apply
if ! grep -q 'depends_on.*talos_machine_configuration_apply' "$TALOS_FILE"; then
  echo "  Bootstrap must depend on config apply"
  ((ERRORS++))
fi

# Kubeconfig must depend on bootstrap
if ! grep -q 'depends_on.*talos_machine_bootstrap' "$TALOS_FILE"; then
  echo "  Kubeconfig must depend on bootstrap"
  ((ERRORS++))
fi

# Must have LUKS2 encryption config patches (STATE and EPHEMERAL)
for vol in STATE EPHEMERAL; do
  if ! grep -q "name.*=.*\"$vol\"" "$TALOS_FILE"; then
    echo "  Missing LUKS2 volume encryption for $vol"
    ((ERRORS++))
  fi
done

# Must use HostnameConfig (v1alpha1 multi-doc format, not legacy machine.network.hostname)
if ! grep -q 'HostnameConfig' "$TALOS_FILE"; then
  echo "  Must use HostnameConfig (not legacy hostname field)"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS.

**Step 3: Review config patches**

Read `terraform/talos.tf:46-118` and verify each patch:
1. Install patch (line 47-66): disk, image, network interface with static IP
2. Kubelet/cluster patch (line 67-82): seccomp, node-ip, allow scheduling on CP, discovery disabled
3. Hostname patch (line 83-88): HostnameConfig v1alpha1 format
4. STATE encryption (line 89-102): LUKS2 with TPM, SecureBoot check
5. EPHEMERAL encryption (line 103-117): LUKS2 with TPM, SecureBoot check, lockToState

Check for:
- `machine.network.nameservers` — CLAUDE.md says this must be set to external resolvers. Verify it exists or document that it's configured elsewhere.
- Subnet mask hardcoded as `/24` (line 58) — consider making this a variable.

**Step 4: Commit**

```bash
git add tests/test-terraform-talos.sh terraform/talos.tf
git commit -m "test: add TalosOS configuration validation"
```

**LIVE:** `talosctl health` and `talosctl get machinestatus`

---

### Task 11: Review outputs.tf and secrets (Phase 2.4)

Verify output sensitivity and SOPS encryption round-trip.

**Files:**
- Create: `tests/test-terraform-outputs.sh`
- Review: `terraform/outputs.tf:1-16`
- Review: `terraform/secrets.enc.json` (encrypted — verify structure only)

**Step 1: Write outputs test**

Create `tests/test-terraform-outputs.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

OUTPUTS_FILE="$ROOT/terraform/outputs.tf"

# talosconfig and kubeconfig must be marked sensitive
for output in talosconfig kubeconfig; do
  if ! awk "/^output \"$output\"/,/^}/" "$OUTPUTS_FILE" | grep -q 'sensitive.*=.*true'; then
    echo "  Output '$output' must be marked sensitive"
    ((ERRORS++))
  fi
done

# Verify secrets.enc.json is SOPS-encrypted
SECRETS_FILE="$ROOT/terraform/secrets.enc.json"
if [ -f "$SECRETS_FILE" ] && ! grep -q '"sops"' "$SECRETS_FILE"; then
  echo "  terraform/secrets.enc.json is not SOPS-encrypted"
  ((ERRORS++))
fi

# Verify encrypted output files exist
for file in "$ROOT/terraform/output/talosconfig.enc.yaml" "$ROOT/terraform/output/kubeconfig.enc.yaml"; do
  if [ -f "$file" ] && ! grep -q '^sops:' "$file"; then
    echo "  $(basename "$file") is not SOPS-encrypted"
    ((ERRORS++))
  fi
done

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS.

**Step 3: Verify the export/decrypt round-trip works**

**LIVE:** `mise run config:decrypt` — verify `terraform/output/talosconfig.yaml` and `kubeconfig.yaml` are readable.

**Step 4: Commit**

```bash
git add tests/test-terraform-outputs.sh
git commit -m "test: add Terraform output and secrets validation"
```

---

## Phase 3 — Kubernetes

### Task 12: Review Flux layer structure (Phase 3.1)

Verify the Kustomization hierarchy and dependency chain.

**Files:**
- Create: `tests/test-flux-layers.sh`
- Review: `kubernetes/kustomization.yaml`
- Review: `kubernetes/flux-system/kustomization.yaml`
- Review: `kubernetes/flux-system/infrastructure.yaml`
- Review: `kubernetes/flux-system/infrastructure-config.yaml`
- Review: `kubernetes/flux-system/cluster-policies.yaml`
- Review: `kubernetes/flux-system/apps.yaml`

**Step 1: Write Flux layer test**

Create `tests/test-flux-layers.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

K8S="$ROOT/kubernetes"

# Every flux-system Kustomization CRD must reference a directory that exists
for file in "$K8S"/flux-system/{infrastructure,infrastructure-config,cluster-policies,apps}.yaml; do
  [ -f "$file" ] || continue
  name="$(basename "$file" .yaml)"
  # Extract the path from spec.path
  path=$(grep 'path:' "$file" | head -1 | awk '{print $2}' | tr -d '"' | sed 's|^\./||')
  if [ -n "$path" ] && [ ! -d "$ROOT/$path" ]; then
    echo "  $name references missing directory: $path"
    ((ERRORS++))
  fi
done

# Each target directory must have a kustomization.yaml
for dir in infrastructure infrastructure-config cluster-policies apps; do
  if [ ! -f "$K8S/$dir/kustomization.yaml" ]; then
    echo "  kubernetes/$dir/ missing kustomization.yaml"
    ((ERRORS++))
  fi
done

# kustomize build must succeed for each layer
for dir in "$K8S"/*/; do
  if [ -f "${dir}kustomization.yaml" ]; then
    name="$(basename "$dir")"
    if ! kustomize build "$dir" > /dev/null 2>&1; then
      echo "  kustomize build failed for kubernetes/$name/"
      ((ERRORS++))
    fi
  fi
done

# Verify dependency chain: infrastructure-config depends on infrastructure
if ! grep -q 'infrastructure' "$K8S/flux-system/infrastructure-config.yaml"; then
  echo "  infrastructure-config must depend on infrastructure"
  ((ERRORS++))
fi

# Verify dependency chain: cluster-policies depends on infrastructure
if ! grep -q 'infrastructure' "$K8S/flux-system/cluster-policies.yaml"; then
  echo "  cluster-policies must depend on infrastructure"
  ((ERRORS++))
fi

# Verify dependency chain: apps depends on cluster-policies
if ! grep -q 'cluster-policies' "$K8S/flux-system/apps.yaml"; then
  echo "  apps must depend on cluster-policies"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS.

**Step 3: Review SOPS decryption scope**

Check which Flux Kustomizations enable SOPS decryption:
- `infrastructure.yaml` — YES (has secrets)
- `infrastructure-config.yaml` — NO (no secrets)
- `cluster-policies.yaml` — NO (no secrets)
- `apps.yaml` — YES (may have app secrets)

Verify this matches reality.

**Step 4: Commit**

```bash
git add tests/test-flux-layers.sh
git commit -m "test: add Flux layer structure validation"
```

**LIVE:** `flux get kustomizations` — all should show `Ready True`.

---

### Task 13: Review core infrastructure — gateway-api and nfs-provisioner (Phase 3.2)

**Files:**
- Create: `tests/test-infrastructure-components.sh`
- Review: `kubernetes/infrastructure/gateway-api/` (all files)
- Review: `kubernetes/infrastructure/nfs-provisioner/` (all files)
- Review: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Write infrastructure component structure test**

Create `tests/test-infrastructure-components.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

INFRA="$ROOT/kubernetes/infrastructure"

# Every directory listed in infrastructure/kustomization.yaml must exist
while IFS= read -r resource; do
  resource=$(echo "$resource" | tr -d ' -')
  if [ -n "$resource" ] && [ ! -d "$INFRA/$resource" ] && [ ! -f "$INFRA/$resource" ]; then
    echo "  infrastructure/kustomization.yaml references missing: $resource"
    ((ERRORS++))
  fi
done < <(grep -A100 'resources:' "$INFRA/kustomization.yaml" | tail -n+2 | grep '^ *-' | sed 's/^ *- //')

# Every HelmRelease must have:
# - install.crds or a note about CRDs
# - install.remediation.retries
# - upgrade.remediation.retries
while IFS= read -r -d '' hr_file; do
  name="$(basename "$(dirname "$hr_file")")/$(basename "$hr_file")"
  if ! grep -q 'remediation' "$hr_file"; then
    echo "  $name missing remediation configuration"
    ((ERRORS++))
  fi
done < <(find "$INFRA" -name 'helmrelease*.yaml' -print0)

# Every component directory with a HelmRelease must have a HelmRepository
while IFS= read -r -d '' hr_file; do
  dir="$(dirname "$hr_file")"
  if [ ! -f "$dir/helmrepository.yaml" ] && ! ls "$dir"/helmrepository*.yaml >/dev/null 2>&1; then
    # Check parent directory (for nested components like adguard/adguard-home)
    parent="$(dirname "$dir")"
    if [ ! -f "$parent/helmrepository.yaml" ] && ! ls "$parent"/helmrepository*.yaml >/dev/null 2>&1; then
      # Check if it uses a GitRepository instead
      if ! ls "$dir"/gitrepository*.yaml >/dev/null 2>&1; then
        name="$(basename "$dir")"
        # postgres uses cloudnative-pg's HelmRepository, skip
        if [ "$name" != "postgres" ]; then
          echo "  $(basename "$dir") has HelmRelease but no HelmRepository"
          ((ERRORS++))
        fi
      fi
    fi
  fi
done < <(find "$INFRA" -name 'helmrelease*.yaml' -print0)

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: Some HelmReleases may lack remediation. Note failures.

**Step 3: Review gateway-api and nfs-provisioner**

For each component, verify:
- Namespace created correctly
- HelmRelease/GitRepository values match upstream docs
- Resource requests and limits are set
- StorageClass name (`nfs`) matches references in other components

**Step 4: Fix issues and commit**

```bash
git add tests/test-infrastructure-components.sh kubernetes/infrastructure/
git commit -m "test: add infrastructure component structure validation"
```

**LIVE:** `kubectl get storageclass` and `kubectl get gatewayclass`

---

### Task 14: Review networking — cert-manager and traefik (Phase 3.3)

**Files:**
- Review: `kubernetes/infrastructure/cert-manager/` (all files)
- Review: `kubernetes/infrastructure/traefik/` (all files)
- Review: `kubernetes/infrastructure-config/cert-manager-clusterissuer.yaml`
- Review: `kubernetes/infrastructure-config/traefik-certificate.yaml`

**Step 1: Review cert-manager HelmRelease**

Read `kubernetes/infrastructure/cert-manager/helmrelease.yaml` and verify:
- Chart version is current
- CRD install/upgrade strategy
- DNS-01 solver configuration matches DigitalOcean API
- Resource limits are set

**Step 2: Review Traefik HelmRelease**

Read `kubernetes/infrastructure/traefik/helmrelease.yaml` and verify:
- `dependsOn: cert-manager` is set
- Gateway API enabled with correct Gateway name
- hostPort binding on 80/443
- HTTP→HTTPS redirect uses correct v38 syntax (`redirections.entryPoint.to`, not `redirectTo`)
- Wildcard hostname matches certificate
- Resource limits are set

**Step 3: Review CRD-dependent resources**

Read `kubernetes/infrastructure-config/cert-manager-clusterissuer.yaml` and `traefik-certificate.yaml`:
- ClusterIssuer references correct secret name for DigitalOcean token
- Certificate namespace matches Traefik Gateway namespace
- Certificate `dnsNames` includes `*.catinthehack.ca`

**Step 4: Commit any fixes**

```bash
git add kubernetes/infrastructure/cert-manager/ kubernetes/infrastructure/traefik/ kubernetes/infrastructure-config/
git commit -m "refactor: improve cert-manager and traefik configuration"
```

**LIVE:** `kubectl get certificate -A` (should show Ready), `curl -v https://whoami.catinthehack.ca` (valid TLS)

---

### Task 15: Review DNS — adguard and unbound (Phase 3.4)

**Files:**
- Create: `tests/test-dns-config.sh`
- Review: `kubernetes/infrastructure/adguard/` (all files)
- Review: `kubernetes/infrastructure-config/adguard-httproute.yaml`

**Step 1: Write DNS configuration test**

Create `tests/test-dns-config.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

# AdGuard Home must use hostNetwork
AG_HR="$ROOT/kubernetes/infrastructure/adguard/adguard-home/helmrelease.yaml"
if ! grep -q 'hostNetwork.*true' "$AG_HR"; then
  echo "  AdGuard Home HelmRelease must set hostNetwork: true"
  ((ERRORS++))
fi

# AdGuard Home must set dnsPolicy: ClusterFirstWithHostNet
if ! grep -q 'ClusterFirstWithHostNet' "$AG_HR"; then
  echo "  AdGuard Home must use dnsPolicy: ClusterFirstWithHostNet"
  ((ERRORS++))
fi

# Adguard namespace must have privileged PSA label
AG_NS="$ROOT/kubernetes/infrastructure/adguard/namespace.yaml"
if ! grep -q 'privileged' "$AG_NS"; then
  echo "  adguard namespace must have privileged PSA label"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS.

**Step 3: Review AdGuard and Unbound configuration**

Verify:
- AdGuard uses Unbound as sole upstream: `unbound.adguard.svc.cluster.local`
- Unbound has DNSSEC enabled
- DNS rewrite: `*.catinthehack.ca → 192.168.20.100`
- Config seeding works (first-boot only, preserves UI changes)
- Secret contains admin password hash

**Step 4: Commit**

```bash
git add tests/test-dns-config.sh kubernetes/infrastructure/adguard/
git commit -m "test: add DNS configuration validation"
```

**LIVE:** `dig @192.168.20.100 whoami.catinthehack.ca` — should resolve to `192.168.20.100`

---

### Task 16: Review observability — monitoring stack (Phase 3.5)

**Files:**
- Review: `kubernetes/infrastructure/monitoring/` (all files)
- Review: `kubernetes/infrastructure-config/monitoring-httproute-*.yaml` (4 files)
- Review: `kubernetes/flux-system/provider-alertmanager.yaml`
- Review: `kubernetes/flux-system/alert-flux.yaml`

**Step 1: Review kube-prometheus-stack HelmRelease**

Read `kubernetes/infrastructure/monitoring/helmrelease-kube-prometheus-stack.yaml` and verify:
- Prometheus retention: 7d
- Storage: NFS PVC 10Gi
- Grafana datasources include Prometheus
- Alertmanager routes and receivers configured
- Pushover credentials reference mounted secret paths
- Custom alert rules (Flux reconciliation, cert-manager expiry)
- Resource limits on all components

**Step 2: Review Loki HelmRelease**

Read `kubernetes/infrastructure/monitoring/helmrelease-loki.yaml` and verify:
- Single-binary mode with TSDB backend
- Retention: 168h with compactor enabled
- `dependsOn: kube-prometheus-stack`
- Storage: NFS PVC

**Step 3: Review Alloy HelmRelease**

Read `kubernetes/infrastructure/monitoring/helmrelease-alloy.yaml` and verify:
- DaemonSet controller type
- Kubernetes API-based log collection (not file-based — correct for TalosOS)
- Forward destination: `loki.monitoring.svc:3100`
- `dependsOn: loki`

**Step 4: Review Grafana datasource ConfigMap**

Read `kubernetes/infrastructure/monitoring/grafana-datasource-loki.yaml` and verify:
- Label `grafana_datasource: "1"` for sidecar discovery
- Correct Loki URL

**Step 5: Review Flux alerting**

Read `kubernetes/flux-system/provider-alertmanager.yaml` and `alert-flux.yaml`:
- Provider address matches Alertmanager service
- Alert covers correct event sources (GitRepository, Kustomization, HelmRelease, HelmRepository)

**Step 6: Check for duplicate YAML keys**

Run: `kustomize build kubernetes/infrastructure/monitoring/ | python3 -c "import sys, yaml; yaml.safe_load(sys.stdin)"` — this will error on duplicate keys.

**Step 7: Commit any fixes**

```bash
git add kubernetes/infrastructure/monitoring/ kubernetes/flux-system/ kubernetes/infrastructure-config/
git commit -m "refactor: improve monitoring stack configuration"
```

**LIVE:**
- `kubectl get pods -n monitoring` — all Running
- `kubectl get servicemonitor -n monitoring` — all present
- Access Grafana via browser, verify dashboards load

---

### Task 17: Review data — cloudnative-pg and postgres (Phase 3.6)

**Files:**
- Review: `kubernetes/infrastructure/cloudnative-pg/` (all files)
- Review: `kubernetes/infrastructure/postgres/` (all files)

**Step 1: Review CloudNativePG operator**

Read `kubernetes/infrastructure/cloudnative-pg/helmrelease.yaml` and verify:
- CRD install/upgrade strategy
- Namespace: `cnpg-system`
- Resource limits

**Step 2: Review PostgreSQL cluster**

Read `kubernetes/infrastructure/postgres/helmrelease.yaml` and verify:
- `dependsOn: cloudnative-pg/cloudnative-pg` (cross-namespace)
- Single instance, PostgreSQL 17.8
- Storage: NFS 5Gi (document fsync risk from CLAUDE.md)
- InitDB creates `authentik` database with correct owner
- Secret references correct credentials

**Step 3: Commit any fixes**

```bash
git add kubernetes/infrastructure/cloudnative-pg/ kubernetes/infrastructure/postgres/
git commit -m "refactor: improve CloudNativePG and PostgreSQL configuration"
```

**LIVE:** `kubectl get cluster -n postgres` — should show `Cluster is Ready`

---

### Task 18: Review identity — authentik and proxy outpost (Phase 3.7)

**Files:**
- Create: `tests/test-authentik-config.sh`
- Review: `kubernetes/infrastructure/authentik/` (all files)

**Step 1: Write Authentik configuration test**

Create `tests/test-authentik-config.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

AUTHENTIK_DIR="$ROOT/kubernetes/infrastructure/authentik"

# HelmRelease must reference existingSecret
HR="$AUTHENTIK_DIR/helmrelease.yaml"
if ! grep -q 'existingSecret' "$HR"; then
  echo "  Authentik HelmRelease must use existingSecret pattern"
  ((ERRORS++))
fi

# Outpost deployment must exist
if [ ! -f "$AUTHENTIK_DIR/outpost-deployment.yaml" ]; then
  echo "  Missing outpost-deployment.yaml"
  ((ERRORS++))
fi

# Outpost image tag should match Authentik chart version
if [ -f "$AUTHENTIK_DIR/outpost-deployment.yaml" ]; then
  OUTPOST_TAG=$(grep 'image:' "$AUTHENTIK_DIR/outpost-deployment.yaml" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  CHART_VERSION=$(grep 'version:' "$HR" | head -1 | awk '{print $2}')
  if [ -n "$OUTPOST_TAG" ] && [ -n "$CHART_VERSION" ] && [ "$OUTPOST_TAG" != "$CHART_VERSION" ]; then
    echo "  Outpost image tag ($OUTPOST_TAG) does not match chart version ($CHART_VERSION)"
    ((ERRORS++))
  fi
fi

# Blueprints ConfigMap must exist
if [ ! -f "$AUTHENTIK_DIR/blueprints-configmap.yaml" ]; then
  echo "  Missing blueprints-configmap.yaml"
  ((ERRORS++))
fi

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS. If outpost tag mismatches chart version, fix it.

**Step 3: Review all Authentik resources**

Verify:
- `secret.enc.yaml` contains all required `AUTHENTIK_*` keys
- `outpost-secret.enc.yaml` contains `AUTHENTIK_TOKEN` matching `AUTHENTIK_BOOTSTRAP_TOKEN`
- Blueprint files are numbered for processing order
- Blueprint cross-file references use `!Find` (not `!KeyOf`)
- Outpost Deployment uses `AUTHENTIK_INSECURE=true` for in-cluster hairpin

**Step 4: Commit**

```bash
git add tests/test-authentik-config.sh kubernetes/infrastructure/authentik/
git commit -m "test: add Authentik configuration validation"
```

**LIVE:** Access Authentik admin panel, verify outpost pod is Running.

---

### Task 19: Review policies — kyverno, image verification, forward-auth (Phase 3.8)

**Files:**
- Review: `kubernetes/infrastructure/kyverno/` (all files)
- Review: `kubernetes/cluster-policies/` (all files)

**Step 1: Review Kyverno HelmRelease**

Read `kubernetes/infrastructure/kyverno/helmrelease.yaml` and verify:
- All controller components enabled (admission, background, cleanup, reports)
- Resource limits on each controller
- CRD install/upgrade strategy

**Step 2: Review ClusterPolicies**

Read `kubernetes/cluster-policies/clusterpolicy-verify-images.yaml`:
- Audit mode (failurePolicy: Audit)
- Correct Sigstore issuer regex
- Excluded namespaces (kube-system, kyverno)

Read `kubernetes/cluster-policies/clusterpolicy-inject-forward-auth.yaml`:
- Targets all HTTPRoutes
- Injects correct Traefik middleware annotation
- Opt-out label: `auth.catinthehack.ca/skip: "true"`

Read `kubernetes/cluster-policies/middleware-forward-auth.yaml`:
- Correct Traefik ForwardAuth CRD
- Points to Authentik proxy outpost service

**Step 3: Commit any fixes**

```bash
git add kubernetes/infrastructure/kyverno/ kubernetes/cluster-policies/
git commit -m "refactor: improve Kyverno and policy configuration"
```

**LIVE:**
- `kubectl get policyreport -A` — check for violations
- `kubectl get httproute -A -o yaml | grep traefik.io/middleware` — verify injection

---

### Task 20: Review apps — whoami (Phase 3.9)

**Files:**
- Review: `kubernetes/apps/whoami/` (all files)
- Review: `kubernetes/apps/kustomization.yaml`

**Step 1: Review the template app**

Read all files in `kubernetes/apps/whoami/` and verify:
- Namespace created
- Deployment has resource requests and limits
- Service targets correct port
- HTTPRoute references `traefik-gateway` in `traefik` namespace
- HTTPRoute uses correct hostname under `*.catinthehack.ca`
- Kustomization lists all resources

**Step 2: Verify the app pattern is complete and reusable**

Check whether a new app could be created by copying `whoami/` and changing names/hostnames. Document any missing pieces (e.g., health checks, readiness probes).

**Step 3: Commit any fixes**

```bash
git add kubernetes/apps/
git commit -m "refactor: improve whoami app template"
```

**LIVE:** `curl -s https://whoami.catinthehack.ca` — should return 200

---

### Task 21: Review infrastructure-config (Phase 3.10)

**Files:**
- Create: `tests/test-infrastructure-config.sh`
- Review: `kubernetes/infrastructure-config/` (all files)

**Step 1: Write infrastructure-config test**

Create `tests/test-infrastructure-config.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

IC_DIR="$ROOT/kubernetes/infrastructure-config"

# Every file must have a namespace set (these are CRD-dependent resources)
for file in "$IC_DIR"/*.yaml; do
  [ "$(basename "$file")" = "kustomization.yaml" ] && continue
  if ! grep -q 'namespace:' "$file"; then
    echo "  $(basename "$file") missing namespace metadata"
    ((ERRORS++))
  fi
done

# All files must be listed in kustomization.yaml
KUSTOMIZATION="$IC_DIR/kustomization.yaml"
for file in "$IC_DIR"/*.yaml; do
  name="$(basename "$file")"
  [ "$name" = "kustomization.yaml" ] && continue
  if ! grep -q "$name" "$KUSTOMIZATION"; then
    echo "  $name not listed in infrastructure-config/kustomization.yaml"
    ((ERRORS++))
  fi
done

# File naming must be component-prefixed
for file in "$IC_DIR"/*.yaml; do
  name="$(basename "$file")"
  [ "$name" = "kustomization.yaml" ] && continue
  if ! echo "$name" | grep -qE '^[a-z]+-'; then
    echo "  $name does not follow component-prefix naming convention"
    ((ERRORS++))
  fi
done

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test**

Run: `mise run test`
Expected: PASS.

**Step 3: Review each resource**

Verify each file has correct:
- `apiVersion` and `kind` matching a CRD from infrastructure layer
- Namespace matching the component that consumes it
- References to correct Secret/Gateway/Service names

**Step 4: Commit**

```bash
git add tests/test-infrastructure-config.sh kubernetes/infrastructure-config/
git commit -m "test: add infrastructure-config validation"
```

**LIVE:** `flux get kustomization infrastructure-config` — should show `Ready True`

---

## Phase 4 — Cross-cutting Review

### Task 22: Consistency audit (Phase 4.1)

**Files:**
- Create: `tests/test-consistency.sh`
- Review: All `kubernetes/infrastructure/*/helmrelease*.yaml`

**Step 1: Write consistency test**

Create `tests/test-consistency.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

# Every HelmRelease must have install.remediation.retries and upgrade.remediation.retries
while IFS= read -r -d '' file; do
  name="$(echo "$file" | sed "s|$ROOT/||")"
  if ! grep -q 'remediation' "$file"; then
    echo "  $name missing remediation configuration"
    ((ERRORS++))
  fi
done < <(find "$ROOT/kubernetes" -name 'helmrelease*.yaml' -print0)

# Every namespace.yaml must have consistent labels
while IFS= read -r -d '' file; do
  name="$(echo "$file" | sed "s|$ROOT/||")"
  # Check for PSA labels where required (traefik, adguard need privileged)
  ns_name=$(grep 'name:' "$file" | head -1 | awk '{print $2}')
  case "$ns_name" in
    traefik|adguard)
      if ! grep -q 'privileged' "$file"; then
        echo "  $name ($ns_name) missing privileged PSA label"
        ((ERRORS++))
      fi
      ;;
  esac
done < <(find "$ROOT/kubernetes" -name 'namespace.yaml' -print0)

# Every HelmRelease should set resource requests
while IFS= read -r -d '' file; do
  name="$(echo "$file" | sed "s|$ROOT/||")"
  if ! grep -q 'resources' "$file"; then
    echo "  $name missing resource requests/limits"
    ((ERRORS++))
  fi
done < <(find "$ROOT/kubernetes" -name 'helmrelease*.yaml' -print0)

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test and fix inconsistencies**

Run: `mise run test`
Fix any HelmReleases missing remediation or resource configuration.

**Step 3: Commit**

```bash
git add tests/test-consistency.sh kubernetes/
git commit -m "test: add cross-cutting consistency validation"
```

---

### Task 23: Simplicity audit (Phase 4.2)

**Files:**
- Review: All Kustomization resource lists against actual directories

**Step 1: Check for orphaned resources**

Verify every file in each directory is listed in its `kustomization.yaml`. Verify every entry in each `kustomization.yaml` references an existing file.

**Step 2: Check for over-specified values**

Review HelmRelease values for defaults that are restated explicitly (unnecessary noise). Remove values that match chart defaults.

Use `helm show values <repo>/<chart> --version <version>` to compare.

**Step 3: Check for dead code**

Grep for resources defined but never referenced by any Kustomization or HelmRelease.

**Step 4: Commit**

```bash
git add kubernetes/
git commit -m "refactor: remove unnecessary defaults and dead resources"
```

---

### Task 24: Security audit (Phase 4.3)

**Files:**
- Create: `tests/test-security.sh`

**Step 1: Write security test**

Create `tests/test-security.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

# Enumerate namespaces with privileged PSA — each must be justified
PRIVILEGED_NS=()
while IFS= read -r -d '' file; do
  if grep -q 'privileged' "$file"; then
    ns=$(grep 'name:' "$file" | head -1 | awk '{print $2}')
    PRIVILEGED_NS+=("$ns")
  fi
done < <(find "$ROOT/kubernetes" -name 'namespace.yaml' -print0)

# Only traefik and adguard should be privileged
ALLOWED_PRIVILEGED="traefik adguard"
for ns in "${PRIVILEGED_NS[@]}"; do
  if ! echo "$ALLOWED_PRIVILEGED" | grep -qw "$ns"; then
    echo "  Unexpected privileged namespace: $ns (justify or remove)"
    ((ERRORS++))
  fi
done

# No Secret values should appear in plaintext YAML (except encrypted files)
while IFS= read -r -d '' file; do
  case "$file" in
    *.enc.yaml|*.enc.json) continue ;;
  esac
  # Check for base64-encoded strings that look like secrets
  if grep -qE 'password|token|secret|key' "$file" && grep -qE '^  [a-zA-Z]+: [A-Za-z0-9+/=]{20,}$' "$file"; then
    name="$(echo "$file" | sed "s|$ROOT/||")"
    echo "  $name may contain plaintext secret values"
    ((ERRORS++))
  fi
done < <(find "$ROOT/kubernetes" -name '*.yaml' -print0)

[ "$ERRORS" -eq 0 ]
```

**Step 2: Run test and review findings**

Run: `mise run test`
Review and address any findings.

**Step 3: Assess network policy gaps**

Document which namespaces communicate with each other. Note that no NetworkPolicies exist — this is a known gap tracked in the README roadmap (Step 17).

**Step 4: Commit**

```bash
git add tests/test-security.sh
git commit -m "test: add security audit validation"
```

---

### Task 25: Best practices audit (Phase 4.4)

**Step 1: Run tflint with additional rulesets**

Check if additional tflint plugins would catch issues:
- `tflint-ruleset-terraform` (already enabled with `recommended` preset)
- Consider enabling `all` preset temporarily to see additional findings

Run: `cd terraform && tflint --config=.tflint.hcl`

**Step 2: Run kubeconform with strict mode**

The `mise run check` task already uses `-strict` and `-ignore-missing-schemas`. Review which schemas are missing and whether CRD schemas can be added.

**Step 3: Review Flux patterns against documentation**

Check: @ Use superpowers:context7 to get latest Flux documentation.
- Health checks configured on HelmReleases
- Timeout values appropriate for chart size
- Prune behavior safe (won't delete manually-created resources)

**Step 4: Commit any improvements**

```bash
git add terraform/.tflint.hcl .mise.toml kubernetes/
git commit -m "refactor: apply best practice improvements"
```

---

### Task 26: Helm chart version audit (Phase 4.5)

**Step 1: List all HelmRelease versions**

Extract chart name and version from every HelmRelease:

```bash
grep -r 'chart:' kubernetes/infrastructure/ --include='helmrelease*.yaml' -A5 | grep -E '(name|version):'
```

**Step 2: Compare against latest available**

For each chart, check the latest version:

```bash
helm repo add <repo> <url>
helm search repo <chart> --versions | head -3
```

**Step 3: Evaluate updates**

For each chart with available updates:
- Check changelog for breaking changes
- Check if the update is a security fix
- Note Bitnami freeze impact (if applicable)

**Step 4: Update chart versions where safe**

Only update charts with security fixes or non-breaking patches. Major version bumps require a dedicated PR.

**Step 5: Commit**

```bash
git add kubernetes/infrastructure/
git commit -m "build: update Helm chart versions"
```

**LIVE:** `flux reconcile kustomization infrastructure --with-source` — verify reconciliation succeeds after version bumps.

---

### Task 27: Final documentation update (Phase 4.6)

**Files:**
- Modify: `CLAUDE.md`
- Modify: `ARCHITECTURE.md`
- Modify: `README.md`

**Step 1: Update CLAUDE.md**

Add any new implementation notes, deployment lessons, or convention changes discovered during the review.

**Step 2: Update ARCHITECTURE.md**

Verify all infrastructure components are listed. Update any descriptions that changed during refactoring.

**Step 3: Update README.md roadmap**

Mark completed items. Update any changed instructions.

**Step 4: Run documentation accuracy test**

Run: `mise run test` — the test from Task 2 should still pass.

**Step 5: Commit**

```bash
git add CLAUDE.md ARCHITECTURE.md README.md
git commit -m "docs: update documentation after systematic review"
```

---

## Completion

After all 27 tasks:

1. Run `mise run check` — full suite must pass
2. Run `mise run test` — all tests must pass
3. Create PR with summary of all findings and changes
4. **LIVE:** Full cluster health check:
   - `kubectl get nodes` — Ready
   - `flux get kustomizations` — all Ready
   - `flux get helmreleases -A` — all Ready
   - `talosctl health` — healthy
   - `curl https://whoami.catinthehack.ca` — 200 OK
