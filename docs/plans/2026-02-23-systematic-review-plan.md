# Systematic Codebase Review — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Review and test the entire cloudlab codebase using TDD, one component at a time.

**Architecture:** Three-tier testing — static/unit tests run on every check, security scanning on demand, E2E tests against the live cluster. Each review item follows red-green-refactor.

**Tech Stack:** Terraform test (`.tftest.hcl`), Kyverno CLI, Chainsaw, Trivy, Pluto, kube-linter, bash test runner, tflint, kubeconform, kustomize, mise

---

## Testing Toolchain

| Tier | Tool | Purpose | Runs in |
|------|------|---------|---------|
| Static/Unit | `terraform test` | Variable validation, plan assertions (mocked providers) | `mise run check` |
| Static/Unit | `kyverno test` | Test ClusterPolicies against fixture resources offline | `mise run check` |
| Static/Unit | Bash runner (`tests/test-*.sh`) | Simple structural checks (file exists, listed in kustomization) | `mise run check` |
| Static/Unit | tflint, kubeconform, kustomize, gitleaks | Existing validation pipeline | `mise run check` |
| Security | `trivy config` | Misconfigurations in Terraform + K8s YAML | `mise run security` |
| Security | `pluto` | Deprecated/removed K8s API versions | `mise run security` |
| Security | `kube-linter` | K8s best practices (limits, probes, security context) | `mise run security` |
| E2E | `chainsaw` | Live cluster assertions — DNS, TLS, auth, services | `mise run e2e` |

## Mise Tasks

| Task | Scope |
|------|-------|
| `mise run check` | Existing pipeline + `terraform test` + bash tests + `kyverno test` |
| `mise run security` | `trivy config` + `pluto` + `kube-linter` |
| `mise run e2e` | `chainsaw test` against live cluster |
| `mise run test:all` | `check` + `security` (no E2E — run separately) |

## Conventions

- **Terraform tests:** `terraform/tests/*.tftest.hcl`
- **Kyverno tests:** `tests/kyverno/<test-name>/` (kyverno-test.yaml + fixtures)
- **Bash tests:** `tests/test-*.sh`
- **E2E tests:** `tests/e2e/<test-name>/` (chainsaw-test.yaml + assertions)
- **Commit pattern:** One commit per red-green-refactor cycle
- **Branch:** `refactor/systematic-review`
- **Live verification:** Commands listed as `LIVE:` — run from the main repo (not worktree) for terraform plan, or from anywhere for kubectl/curl

---

## Phase 0 — Housekeeping

### Task 1: Create the bash test runner ✅ DONE

Created `tests/run-all.sh` and `mise run test` task. Integrated into `mise run check`.

---

### Task 2: Set up test frameworks

Install the new testing tools and create the directory structure and mise tasks.

**Files:**
- Modify: `.mise.toml` (add tools + tasks)
- Create: `terraform/tests/` directory
- Create: `tests/kyverno/` directory
- Create: `tests/e2e/` directory

**Step 1: Add new tools to `.mise.toml`**

Add to the `[tools]` section:

```toml
kyverno = "1.17"
"aqua:kyverno/chainsaw" = "0.2.14"
trivy = "0.62"
"aqua:FairwindsOps/pluto" = "5.21"
kube-linter = "0.7"
```

**Step 2: Create directory structure**

```
terraform/tests/          # .tftest.hcl files
tests/kyverno/            # Kyverno CLI test directories
tests/e2e/                # Chainsaw test directories
```

Add a `.gitkeep` in each new directory so they're tracked.

**Step 3: Add mise tasks**

Add to `.mise.toml`:

```toml
[tasks."tf:test"]
description = "Run Terraform tests"
dir = "terraform"
run = "terraform test"

[tasks.security]
description = "Run security scanning (trivy, pluto, kube-linter)"
run = """
set -e
echo "==> Trivy (Terraform)"
trivy config --severity HIGH,CRITICAL terraform/
echo "==> Trivy (Kubernetes)"
trivy config --severity HIGH,CRITICAL kubernetes/
echo "==> Pluto"
pluto detect-files -d kubernetes/ --ignore-deprecations --ignore-removals --target-versions k8s=v1.32.0
echo "==> kube-linter"
kube-linter lint kubernetes/ --config .kube-linter.yaml || true
"""

[tasks.e2e]
description = "Run E2E tests against the live cluster"
run = """
set -e
echo "==> Chainsaw E2E"
chainsaw test --test-dir tests/e2e/
"""

[tasks."test:all"]
description = "Run all tests (check + security)"
run = """
set -e
mise run check
mise run security
"""
```

**Step 4: Add `terraform test` to the check task**

Insert in the check task's run block after the Terraform validation section:

```bash
echo "==> Terraform Tests"
(cd terraform && terraform test)
```

**Step 5: Add `kyverno test` to the check task**

Insert in the check task's run block after Kubernetes validation:

```bash
if [ -d tests/kyverno ] && ls tests/kyverno/*/kyverno-test.yaml >/dev/null 2>&1; then
  echo "==> Kyverno Policy Tests"
  kyverno test tests/kyverno/
fi
```

**Step 6: Create a minimal kube-linter config**

Create `.kube-linter.yaml` at project root:

```yaml
checks:
  addAllBuiltIn: true
  exclude:
    - "unset-cpu-requirements"       # We set requests, not limits everywhere
    - "unset-memory-requirements"    # Same
```

This config can be tuned as we discover false positives during the review.

**Step 7: Install tools and verify**

Run: `mise install`
Run: `mise run check` — existing pipeline still passes, terraform test runs with no test files
Run: `mise run security` — trivy, pluto, kube-linter produce initial output (review but don't fix yet)

**Step 8: Commit**

```bash
git add .mise.toml .kube-linter.yaml terraform/tests/.gitkeep tests/kyverno/.gitkeep tests/e2e/.gitkeep
git commit -m "build: add test frameworks (kyverno, chainsaw, trivy, pluto, kube-linter)"
```

---

### Task 3: Documentation accuracy (Phase 0.1)

Verify documentation references match actual files and directories.

**Files:**
- Create: `tests/test-docs-accuracy.sh`
- Review: `CLAUDE.md`, `ARCHITECTURE.md`, `README.md`

**Step 1: Write the failing test**

Create `tests/test-docs-accuracy.sh` — a bash script that extracts file/directory references from documentation and verifies they exist. Check all paths mentioned in CLAUDE.md's Key Files table, ARCHITECTURE.md's infrastructure component list, and README.md.

**Step 2: Run to see what fails**

Run: `mise run test`

**Step 3: Fix documentation to match reality**

Update stale references, add missing components, correct paths.

**Step 4: Commit**

```bash
git add tests/test-docs-accuracy.sh CLAUDE.md ARCHITECTURE.md README.md
git commit -m "docs: fix stale references found by documentation accuracy test"
```

---

### Task 4: Tool version audit (Phase 0.2)

Check `.mise.toml` tool versions for available updates.

**Step 1:** Run `mise outdated`
**Step 2:** Evaluate each update (security fixes, breaking changes)
**Step 3:** Update safe versions in `.mise.toml`
**Step 4:** Run `mise install && mise run check`
**Step 5:** Commit

---

### Task 5: Encryption and secret scanning config (Phase 0.3)

Verify SOPS creation rules cover all encrypted files and gitleaks rules are sufficient.

**Files:**
- Create: `tests/test-sops-coverage.sh`
- Review: `.sops.yaml`, `.gitleaks.toml`

**Step 1:** Write `tests/test-sops-coverage.sh` verifying every `.enc.` file is SOPS-encrypted
**Step 2:** Run tests, fix any issues
**Step 3:** Commit

---

## Phase 1 — Validation Pipeline

### Task 6: Review and integrate mise tasks (Phase 1.1)

Review all mise tasks for correctness. Verify the `check`, `security`, and `e2e` tasks work end-to-end.

**Files:**
- Create: `tests/test-check-catches-bad-tf.sh`
- Create: `tests/test-check-catches-bad-yaml.sh`
- Modify: `.mise.toml` (fix any issues found)

**Step 1:** Write test that verifies `terraform validate` catches malformed .tf files
**Step 2:** Write test that verifies kubeconform catches invalid YAML
**Step 3:** Review each mise task for correctness, error handling, edge cases
**Step 4:** Run `mise run security` and review initial findings (trivy, pluto, kube-linter output)
**Step 5:** Commit

---

### Task 7: Review lefthook hooks (Phase 1.2)

**Files:**
- Create: `tests/test-hook-check-parity.sh`
- Review: `lefthook.yml`

**Step 1:** Write test verifying lefthook hooks match mise run check coverage
**Step 2:** Compare hook speed vs full check
**Step 3:** Commit

---

### Task 8: Review GitHub Actions CI (Phase 1.3)

**Files:**
- Create: `tests/test-ci-parity.sh`
- Review: `.github/workflows/check.yml`

**Step 1:** Write test verifying CI runs the same validations as local check
**Step 2:** Review for improvements (caching, action versions)
**Step 3:** Commit

---

## Phase 2 — Terraform (using `.tftest.hcl`)

### Task 9: Review versions.tf and variables.tf (Phase 2.1)

Write Terraform native tests for variable validation. Review provider constraints.

**Files:**
- Create: `terraform/tests/variables.tftest.hcl`
- Review: `terraform/versions.tf:1-18`
- Review: `terraform/variables.tf:1-118`

**Step 1: Write variable validation tests**

Create `terraform/tests/variables.tftest.hcl`:

```hcl
mock_provider "proxmox" {}
mock_provider "talos" {}
mock_provider "sops" {}

# Valid configuration plans successfully
run "valid_config" {
  command = plan
  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }
}

# Rejects non-HTTPS proxmox endpoint
run "rejects_http_endpoint" {
  command = plan
  variables {
    proxmox_endpoint = "http://pve.example.com:8006"
  }
  expect_failures = [var.proxmox_endpoint]
}

# Rejects invalid IP for talos_node_ip
run "rejects_invalid_ip" {
  command = plan
  variables {
    talos_node_ip = "not-an-ip"
  }
  expect_failures = [var.talos_node_ip]
}

# Rejects invalid talos_version format
run "rejects_bad_talos_version" {
  command = plan
  variables {
    talos_version = "1.12.4"  # missing v prefix
  }
  expect_failures = [var.talos_version]
}

# Rejects invalid schematic_id
run "rejects_short_schematic" {
  command = plan
  variables {
    talos_schematic_id = "abc123"
  }
  expect_failures = [var.talos_schematic_id]
}

# Rejects CPU cores out of range
run "rejects_too_many_cores" {
  command = plan
  variables {
    vm_cpu_cores = 32
  }
  expect_failures = [var.vm_cpu_cores]
}

# Rejects insufficient memory
run "rejects_low_memory" {
  command = plan
  variables {
    vm_memory_mb = 512
  }
  expect_failures = [var.vm_memory_mb]
}

# Rejects small disk
run "rejects_small_disk" {
  command = plan
  variables {
    vm_disk_gb = 5
  }
  expect_failures = [var.vm_disk_gb]
}
```

**Step 2: Run tests**

Run: `mise run tf:test` or `cd terraform && terraform test`
Expected: All tests pass (valid config succeeds, invalid inputs fail validation).

**Step 3: Review variable validation completeness**

Check each variable for:
- `proxmox_endpoint`: Only checks `^https://` — consider full URL validation
- `talos_node_ip` / `gateway`: Regex allows octets >255 — decide whether to tighten
- `proxmox_ssh_username` / `proxmox_node_name`: No validation — add non-empty checks if needed

**Step 4: Commit**

```bash
git add terraform/tests/variables.tftest.hcl terraform/variables.tf terraform/versions.tf
git commit -m "test: add Terraform variable validation tests"
```

**LIVE (from main repo):** `mise run tf plan` — expect no changes.

---

### Task 10: Review main.tf (Phase 2.2)

Write Terraform tests for resource configuration. Review for hardcoded values.

**Files:**
- Create: `terraform/tests/resources.tftest.hcl`
- Review: `terraform/main.tf:1-99`

**Step 1: Write resource plan tests**

Create `terraform/tests/resources.tftest.hcl` with mocked providers:

```hcl
mock_provider "proxmox" {
  override_resource {
    target = proxmox_virtual_environment_vm.talos
    values = {
      ipv4_addresses = [["127.0.0.1", "192.168.20.50"]]
    }
  }
}
mock_provider "talos" {}
mock_provider "sops" {
  override_data {
    target = data.sops_file.secrets
    values = {
      data = {
        proxmox_api_token = "test@pam!test=fake-token"
      }
    }
  }
}

run "plan_creates_expected_resources" {
  command = plan

  variables {
    proxmox_endpoint   = "https://pve.example.com:8006"
    talos_node_ip      = "192.168.20.100"
    gateway            = "192.168.20.1"
    talos_schematic_id = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
  }

  # Assert VM resource is planned
  assert {
    condition     = proxmox_virtual_environment_vm.talos.name == "talos-cp-1"
    error_message = "VM name should default to talos-cp-1"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.talos.machine == "q35"
    error_message = "VM should use q35 machine type"
  }
}
```

**Step 2: Run tests and review for hardcoded values**

Check `main.tf` for `datastore_id = "local-lvm"`, `bridge = "vmbr0"` — decide whether to variablize.

**Step 3: Commit**

---

### Task 11: Review talos.tf (Phase 2.3)

Write Terraform tests for TalosOS config. Review bootstrap ordering.

**Files:**
- Create: `terraform/tests/talos.tftest.hcl`
- Review: `terraform/talos.tf:1-137`

**Step 1:** Write tests verifying config patches produce expected structure (LUKS2, HostnameConfig, network interface)
**Step 2:** Review bootstrap ordering (DHCP for apply, static for bootstrap)
**Step 3:** Check for missing `machine.network.nameservers` (documented requirement in CLAUDE.md)
**Step 4:** Commit

**LIVE:** `talosctl health` and `talosctl get machinestatus`

---

### Task 12: Review outputs.tf and secrets (Phase 2.4)

Write Terraform tests for output sensitivity. Review SOPS encryption.

**Files:**
- Add tests to: `terraform/tests/resources.tftest.hcl` (assert on outputs)
- Review: `terraform/outputs.tf:1-16`

**Step 1:** Add output assertions to existing test (verify `sensitive = true` on talosconfig and kubeconfig)
**Step 2:** Review secrets.enc.json structure
**Step 3:** Commit

**LIVE:** `mise run config:decrypt` — verify round-trip works.

---

## Phase 3 — Kubernetes

### Task 13: Review Flux layer structure (Phase 3.1)

Verify Kustomization hierarchy and dependency chain.

**Files:**
- Create: `tests/test-flux-layers.sh`
- Review: `kubernetes/flux-system/*.yaml`

**Step 1:** Write bash test verifying:
- Every Flux Kustomization CRD references an existing directory
- Each target directory has a kustomization.yaml
- `kustomize build` succeeds for each layer
- Dependency chain: infrastructure-config and cluster-policies depend on infrastructure; apps depends on cluster-policies

**Step 2:** Run tests, fix issues
**Step 3:** Commit

**LIVE:** `flux get kustomizations` — all Ready.

---

### Task 14: Review core infrastructure — gateway-api and nfs-provisioner (Phase 3.2)

**Files:**
- Create: `tests/test-infrastructure-components.sh`
- Review: `kubernetes/infrastructure/gateway-api/` and `kubernetes/infrastructure/nfs-provisioner/`

**Step 1:** Write bash test verifying:
- Every directory listed in infrastructure/kustomization.yaml exists
- Every HelmRelease has remediation configuration
- Every component directory with a HelmRelease has a HelmRepository (or uses a shared one)

**Step 2:** Review gateway-api commit pin freshness, nfs-provisioner StorageClass name
**Step 3:** Commit

**LIVE:** `kubectl get storageclass` and `kubectl get gatewayclass`

---

### Task 15: Review networking — cert-manager and traefik (Phase 3.3)

**Review:** cert-manager and traefik HelmReleases, ClusterIssuer, Certificate.

**Step 1:** Review cert-manager chart version, CRD strategy, DNS-01 config
**Step 2:** Review traefik Gateway API config, hostPort, redirect syntax (v38 `redirections.entryPoint.to`)
**Step 3:** Review infrastructure-config CRD-dependent resources (ClusterIssuer, Certificate)
**Step 4:** Commit any fixes

**LIVE:** `kubectl get certificate -A` (Ready), `curl -v https://whoami.catinthehack.ca` (valid TLS)

---

### Task 16: Review DNS — adguard and unbound (Phase 3.4)

**Files:**
- Create: `tests/test-dns-config.sh`
- Review: `kubernetes/infrastructure/adguard/`

**Step 1:** Write bash test verifying hostNetwork, dnsPolicy, privileged PSA label
**Step 2:** Review Unbound recursive resolver config, DNS rewrite rules
**Step 3:** Commit

**LIVE:** `dig @192.168.20.100 whoami.catinthehack.ca`

---

### Task 17: Review observability — monitoring stack (Phase 3.5)

**Review:** kube-prometheus-stack, Loki, Alloy HelmReleases. Flux alerting.

**Step 1:** Review prometheus retention, storage, alert rules
**Step 2:** Review Loki TSDB config, retention, compactor
**Step 3:** Review Alloy DaemonSet, Kubernetes API-based collection
**Step 4:** Review Flux alert/provider resources
**Step 5:** Check for duplicate YAML keys
**Step 6:** Commit

**LIVE:** `kubectl get pods -n monitoring` (all Running), Grafana dashboards load

---

### Task 18: Review data — cloudnative-pg and postgres (Phase 3.6)

**Review:** CloudNativePG operator and PostgreSQL cluster.

**Step 1:** Review operator CRD strategy, namespace separation
**Step 2:** Review PostgreSQL cluster config (instances, storage, initdb)
**Step 3:** Commit

**LIVE:** `kubectl get cluster -n postgres` (healthy)

---

### Task 19: Review identity — authentik and proxy outpost (Phase 3.7)

**Files:**
- Create: `tests/test-authentik-config.sh`
- Review: `kubernetes/infrastructure/authentik/`

**Step 1:** Write bash test verifying existingSecret pattern, outpost image tag matches chart version, blueprints exist
**Step 2:** Review blueprint cross-file references (`!Find` vs `!KeyOf`)
**Step 3:** Commit

**LIVE:** Authentik admin panel loads, outpost pod Running

---

### Task 20: Review policies with Kyverno CLI (Phase 3.8)

Test ClusterPolicies offline using Kyverno CLI. This is the first task using the Kyverno test framework.

**Files:**
- Create: `tests/kyverno/forward-auth-injection/kyverno-test.yaml`
- Create: `tests/kyverno/forward-auth-injection/resource.yaml`
- Create: `tests/kyverno/forward-auth-injection/patched-resource.yaml`
- Create: `tests/kyverno/forward-auth-injection/values.yaml`
- Review: `kubernetes/cluster-policies/`

**Step 1: Write Kyverno test for forward-auth injection**

Create `tests/kyverno/forward-auth-injection/kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: inject-forward-auth
policies:
- ../../../kubernetes/cluster-policies/clusterpolicy-inject-forward-auth.yaml
resources:
- resource.yaml
variables: values.yaml
results:
- policy: inject-authentik-forward-auth
  rule: inject-forward-auth
  resources:
  - whoami
  patchedResources: patched-resource.yaml
  kind: HTTPRoute
  result: pass
```

Create fixture `resource.yaml` (plain HTTPRoute) and `patched-resource.yaml` (with injected annotation).

**Step 2: Write test for opt-out label**

Create `tests/kyverno/forward-auth-skip/` with an HTTPRoute that has `auth.catinthehack.ca/skip: "true"` label. Verify it is NOT mutated.

**Step 3: Run Kyverno tests**

Run: `kyverno test tests/kyverno/`
Expected: All tests pass.

**Step 4: Review image verification policy**

Read `clusterpolicy-verify-images.yaml` — verify audit mode, Sigstore issuer regex, excluded namespaces.

**Step 5: Commit**

```bash
git add tests/kyverno/ kubernetes/cluster-policies/
git commit -m "test: add Kyverno CLI tests for forward-auth injection policy"
```

**LIVE:** `kubectl get policyreport -A`

---

### Task 21: Review apps — whoami (Phase 3.9)

**Review:** whoami app template.

**Step 1:** Review completeness as a reusable template (namespace, deployment, service, httproute)
**Step 2:** Verify resource requests/limits, health probes
**Step 3:** Commit

**LIVE:** `curl -s https://whoami.catinthehack.ca` — 200 OK

---

### Task 22: Review infrastructure-config (Phase 3.10)

**Files:**
- Create: `tests/test-infrastructure-config.sh`
- Review: `kubernetes/infrastructure-config/`

**Step 1:** Write bash test verifying namespace metadata, file naming convention, kustomization listing
**Step 2:** Verify every resource type has its CRD in the infrastructure layer
**Step 3:** Commit

**LIVE:** `flux get kustomization infrastructure-config` — Ready

---

## Phase 4 — Cross-cutting Review

### Task 23: Consistency audit (Phase 4.1)

**Files:**
- Create: `tests/test-consistency.sh`

**Step 1:** Write bash test checking:
- Every HelmRelease has remediation configuration
- Privileged namespaces have PSA labels (only traefik, adguard expected)
- Every HelmRelease sets resource requests

**Step 2:** Fix inconsistencies
**Step 3:** Commit

---

### Task 24: Simplicity audit (Phase 4.2)

**Step 1:** Check for orphaned resources (defined but not in any kustomization)
**Step 2:** Review HelmRelease values for over-specified defaults (using `helm show values`)
**Step 3:** Remove dead code, unnecessary defaults
**Step 4:** Commit

---

### Task 25: Security audit with Trivy, Pluto, kube-linter (Phase 4.3)

Run security scanning tools and address findings.

**Step 1: Run Trivy**

Run: `trivy config --severity HIGH,CRITICAL terraform/`
Run: `trivy config --severity HIGH,CRITICAL kubernetes/`

Review findings. Fix genuine security issues. Suppress false positives via `.trivyignore`.

**Step 2: Run Pluto**

Run: `pluto detect-files -d kubernetes/ --target-versions k8s=v1.32.0`

Review deprecated API findings. Update any resources using removed APIs.

**Step 3: Run kube-linter**

Run: `kube-linter lint kubernetes/ --config .kube-linter.yaml`

Review findings. Update `.kube-linter.yaml` to exclude false positives. Fix genuine issues.

**Step 4: Audit privileged namespaces, RBAC, secret exposure**

Manual review of:
- Which namespaces are privileged and why
- RBAC scope (overly broad ClusterRoleBindings?)
- Secret exposure patterns (env vars vs volume mounts)
- Network policy gaps (none exist — document risk)

**Step 5: Commit**

```bash
git add .trivyignore .kube-linter.yaml kubernetes/
git commit -m "security: address findings from trivy, pluto, and kube-linter"
```

---

### Task 26: Best practices audit (Phase 4.4)

**Step 1:** Run tflint with `all` preset temporarily — review additional findings
**Step 2:** Review kubeconform coverage — which schemas are missing? Can we remove `-ignore-missing-schemas`?
**Step 3:** Review Flux patterns against documentation (health checks, timeouts, prune safety)
**Step 4:** Commit

---

### Task 27: Helm chart version audit (Phase 4.5)

**Step 1:** Extract all chart names and versions from HelmReleases
**Step 2:** Compare against latest available (`helm search repo`)
**Step 3:** Evaluate updates (security fixes, breaking changes, Bitnami freeze)
**Step 4:** Update safe versions, commit

**LIVE:** `flux reconcile kustomization infrastructure --with-source`

---

### Task 28: Final documentation update (Phase 4.6)

**Step 1:** Update CLAUDE.md with new test tools, tasks, and conventions
**Step 2:** Update ARCHITECTURE.md with any structural changes
**Step 3:** Update README.md roadmap
**Step 4:** Re-run `mise run test` — docs accuracy test still passes
**Step 5:** Commit

---

## Phase 5 — E2E Tests

### Task 29: Write Chainsaw E2E tests — cluster health

Write E2E tests that verify the cluster is operational after deployment.

**Files:**
- Create: `tests/e2e/flux-healthy/chainsaw-test.yaml`
- Create: `tests/e2e/flux-healthy/assert-kustomizations.yaml`
- Create: `tests/e2e/helmreleases-ready/chainsaw-test.yaml`
- Create: `tests/e2e/helmreleases-ready/assert-helmreleases.yaml`

**Step 1: Flux health test**

```yaml
# tests/e2e/flux-healthy/chainsaw-test.yaml
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata:
  name: flux-healthy
spec:
  steps:
  - try:
    - assert:
        file: assert-kustomizations.yaml
```

```yaml
# tests/e2e/flux-healthy/assert-kustomizations.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
status:
  conditions:
  - type: Ready
    status: "True"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-config
  namespace: flux-system
status:
  conditions:
  - type: Ready
    status: "True"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-policies
  namespace: flux-system
status:
  conditions:
  - type: Ready
    status: "True"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
status:
  conditions:
  - type: Ready
    status: "True"
```

**Step 2: HelmRelease health test**

Assert all HelmReleases are Ready across all namespaces.

**Step 3: Run and verify**

Run: `mise run e2e`
Expected: All cluster health assertions pass.

**Step 4: Commit**

---

### Task 30: Write Chainsaw E2E tests — services

Write E2E tests for DNS, TLS, and authentication.

**Files:**
- Create: `tests/e2e/dns-resolution/chainsaw-test.yaml`
- Create: `tests/e2e/tls-certificate/chainsaw-test.yaml`
- Create: `tests/e2e/auth-gateway/chainsaw-test.yaml`

**Step 1: DNS resolution test**

```yaml
# tests/e2e/dns-resolution/chainsaw-test.yaml
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata:
  name: dns-resolution
spec:
  steps:
  - try:
    - script:
        content: |
          dig +short whoami.catinthehack.ca @192.168.20.100
        check:
          ($stdout): '192.168.20.100'
```

**Step 2: TLS certificate test**

Use `curl` to verify valid TLS on `https://whoami.catinthehack.ca`.

**Step 3: Auth gateway test**

Verify unauthenticated requests are redirected to Authentik login.

**Step 4: Run and verify**

Run: `mise run e2e`

**Step 5: Commit**

---

## Completion

After all 30 tasks:

1. `mise run check` — full static suite passes (terraform, kubeconform, bash tests, kyverno tests)
2. `mise run security` — trivy, pluto, kube-linter clean (or known suppressions documented)
3. `mise run e2e` — all live cluster assertions pass
4. Create PR with summary of all findings and changes
