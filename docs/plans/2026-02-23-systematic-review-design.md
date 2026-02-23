# Systematic Codebase Review

Review and test the entire cloudlab codebase one piece at a time using test-driven development.

## Goals

1. **Verify correctness** — confirm every component works as intended, both statically and against the live cluster.
2. **Improve quality** — eliminate duplication, inconsistency, dead code, and unnecessary complexity.
3. **Strengthen the safety net** — add tests and validation so future changes break loudly and early.

## Review Cycle

Every piece follows red-green-refactor with live verification:

| Step | Action | Output |
|------|--------|--------|
| **Read** | Review the code together; build shared understanding | Summary of purpose and behavior |
| **Red** | Write tests that define expected behavior; observe failures | Failing tests exposing bugs or gaps |
| **Green** | Make the minimum fix to pass each test | Passing tests, no extras |
| **Refactor** | Simplify, deduplicate, restructure — tests stay green | Clean code, same behavior |
| **Static verify** | Run `mise run check` | Full suite passes |
| **Live verify** | Run targeted commands against the cluster | Confirm real-world behavior matches |

Commit after each transition (red, green, refactor) so git history tells the story.

## Phases

### Phase 0 — Housekeeping

Review project-level configuration and documentation before changing any infrastructure code.

#### 0.1 Documentation accuracy

Review `CLAUDE.md`, `ARCHITECTURE.md`, and `README.md` for:
- Stale or contradictory information
- Missing components added since last update
- Roadmap accuracy

**Tests:** Scripted checks that documentation references match actual files and directories.
**Live verify:** None — documentation only.

#### 0.2 Tool version audit

Review `.mise.toml` for:
- Outdated tool versions with available security patches
- Version constraint consistency (exact pins vs ranges)

**Tests:** Add a check that compares pinned versions against latest stable releases.
**Live verify:** `mise doctor` and `mise outdated`.

#### 0.3 Encryption and secret scanning config

Review `.sops.yaml` and `.gitleaks.toml` for:
- File pattern coverage (do all encrypted files match the creation rules?)
- Custom gitleaks rules (is the age key pattern sufficient?)

**Tests:** Verify every `*.enc.*` file in the repo matches a SOPS creation rule.
**Live verify:** `gitleaks git` against the full history.

---

### Phase 1 — Validation Pipeline

Fix the safety net before touching infrastructure code.

#### 1.1 Mise tasks

Review all 13 tasks in `.mise.toml` for:
- Correctness (do they run without error?)
- Completeness (do they validate everything they should?)
- Robustness (do they handle edge cases — empty dirs, missing tools?)

**Tests:** Run each task against known-good and known-bad inputs. The `check` task should catch intentionally malformed Terraform and YAML.
**Live verify:** Run `mise run check` and confirm it passes cleanly.

#### 1.2 Lefthook hooks

Review `lefthook.yml` for:
- Hook coverage (are all pre-commit checks also in `mise run check`?)
- Performance (do hooks run fast enough for developer experience?)
- Consistency with CI

**Tests:** Stage an intentionally bad commit and verify hooks reject it.
**Live verify:** Make a trivial change, commit, observe hook output.

#### 1.3 GitHub Actions CI

Review `.github/workflows/check.yml` for:
- Step ordering and dependency correctness
- Coverage parity with local `mise run check`
- Caching and performance

**Tests:** Compare CI steps against local check task; flag divergences.
**Live verify:** Push a test branch and confirm CI runs the same validations.

---

### Phase 2 — Terraform

Review the infrastructure-as-code layer, file by file.

#### 2.1 versions.tf and variables.tf

Review for:
- Provider version constraints (too loose? too tight?)
- Variable validation rules (missing validations, regex correctness)
- Default values (sensible? documented?)

**Tests:** Add `tflint` custom rules or Terraform test files (`.tftest.hcl`) for variable validation edge cases.
**Live verify:** `terraform validate` and `terraform plan` (no changes expected).

#### 2.2 main.tf

Review Proxmox provider configuration and VM resource for:
- Hardcoded values that belong in variables
- Resource configuration completeness (missing fields, deprecated options)
- TalosOS image download logic

**Tests:** `terraform plan` produces expected resource count with no drift.
**Live verify:** Compare `terraform show` output against actual VM in Proxmox.

#### 2.3 talos.tf

Review machine configuration, patches, bootstrap, and kubeconfig retrieval for:
- Config patch structure and correctness
- Bootstrap ordering (DHCP address for apply, static IP for bootstrap)
- Resource dependencies and lifecycle rules

**Tests:** `terraform plan` shows no drift. Validate config patches against Talos machine config schema.
**Live verify:** `talosctl health` and `talosctl get machinestatus`.

#### 2.4 outputs.tf and secrets

Review for:
- Sensitive marking on all secret outputs
- SOPS encryption of exported configs
- Unnecessary outputs

**Tests:** Verify `terraform output -json` marks sensitive values correctly.
**Live verify:** `mise run config:export` succeeds; encrypted files parse with `sops`.

---

### Phase 3 — Kubernetes

Review GitOps manifests component by component, following the Flux dependency chain.

#### 3.1 Flux layer structure

Review the Kustomization hierarchy and dependency chain for:
- Correct `dependsOn` relationships
- SOPS decryption scope (only where needed)
- Interval and timeout tuning
- Prune safety

**Tests:** `kustomize build` each layer independently. Verify dependency graph has no cycles.
**Live verify:** `flux get kustomizations` — all reconciled, no failures.

#### 3.2 Core infrastructure (gateway-api, nfs-provisioner)

Review for:
- Gateway API CRD version (commit pin freshness)
- NFS provisioner configuration (StorageClass name, NFS path, mount options)
- Consistent HelmRelease structure

**Tests:** `kubeconform` validates generated manifests. Verify StorageClass name matches references elsewhere.
**Live verify:** `kubectl get storageclass` and `kubectl get gatewayclass`.

#### 3.3 Networking (cert-manager, traefik)

Review for:
- Traefik chart values correctness (hostPort, redirect syntax, Gateway config)
- cert-manager DNS-01 solver configuration
- TLS certificate and ClusterIssuer setup

**Tests:** `kustomize build` produces expected resources. Verify chart value nesting against `helm show values`.
**Live verify:** `kubectl get certificate -A` (Ready), `curl -v https://whoami.catinthehack.ca` (valid TLS).

#### 3.4 DNS (adguard, unbound)

Review for:
- hostNetwork and dnsPolicy configuration
- Unbound recursive resolver setup
- Config seeding (first-boot vs persistent config)
- Circular dependency avoidance

**Tests:** Verify pod spec includes `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet`.
**Live verify:** `dig @192.168.20.100 catinthehack.ca` and `kubectl logs -n adguard`.

#### 3.5 Observability (monitoring stack)

Review the tightly-coupled monitoring directory for:
- kube-prometheus-stack values (Prometheus retention, Grafana datasources, Alertmanager config)
- Loki configuration (storage, retention, compactor)
- Alloy log collection (River config, Kubernetes API source)
- Alert rules and notification routing
- Flux PodMonitor and Alert resources

**Tests:** `kustomize build` succeeds. Verify no duplicate YAML keys. Check Alertmanager config references valid secret paths.
**Live verify:** `kubectl get pods -n monitoring` (all running), Grafana dashboards load, `amtool check-config` on Alertmanager.

#### 3.6 Data (cloudnative-pg, postgres)

Review for:
- Operator and cluster separation (cnpg-system vs postgres namespace)
- PostgreSQL cluster configuration (instances, storage, backup)
- Database and role provisioning for Authentik

**Tests:** Verify CRD resources validate against CloudNativePG schema.
**Live verify:** `kubectl get cluster -n postgres` (healthy), `kubectl cnpg status postgres-cluster -n postgres`.

#### 3.7 Identity (authentik, proxy outpost)

Review for:
- existingSecret pattern correctness
- Blueprint structure and cross-file references (`!Find` vs `!KeyOf`)
- Proxy outpost image tag pinning (must match server version)
- Forward-auth middleware configuration

**Tests:** Verify Secret references in HelmRelease match actual Secret keys. Verify outpost image tag matches Authentik chart version.
**Live verify:** Authentik admin panel loads, proxy outpost pod is running, forward-auth redirects unauthenticated requests.

#### 3.8 Policies (kyverno, image verification, forward-auth injection)

Review for:
- Image verification scope and mode (audit vs enforce readiness)
- Forward-auth injection targeting (opt-out label works)
- Policy report output

**Tests:** Apply a test HTTPRoute and verify Kyverno mutates it. Verify excluded namespaces are excluded.
**Live verify:** `kubectl get policyreport -A`, `kubectl get httproute -A -o yaml | grep traefik.io/middleware`.

#### 3.9 Apps (whoami)

Review the template app for:
- Completeness as a reusable pattern
- HTTPRoute correctness (parentRefs, hostnames)
- Resource requests and limits

**Tests:** `kustomize build` produces all expected resources (namespace, deployment, service, httproute).
**Live verify:** `curl https://whoami.catinthehack.ca` returns 200 through the auth gateway.

#### 3.10 Infrastructure-config (CRD-dependent resources)

Review the flat directory of CRD-dependent resources for:
- Correct namespace metadata on each resource
- File naming consistency (component-prefixed)
- All CRD-dependent resources are here, not in infrastructure/

**Tests:** Verify every resource type in this directory has its CRD defined in the infrastructure layer.
**Live verify:** `flux get kustomization infrastructure-config` — reconciled without errors.

---

### Phase 4 — Cross-cutting Review

After reviewing every component, step back and audit the entire codebase.

#### 4.1 Consistency

- Resource naming across namespaces
- Label and annotation patterns (are they uniform?)
- Resource requests and limits (are they set everywhere? reasonable values?)
- SOPS encryption patterns (same structure across all secrets?)
- HelmRelease boilerplate (remediation, CRD handling, intervals)

**Tests:** Script that extracts patterns from all manifests and flags outliers.

#### 4.2 Simplicity

- YAGNI violations (unused config, premature abstractions)
- Dead resources (defined but never referenced)
- Over-specified values (defaults restated explicitly)

**Tests:** Grep for resources not referenced by any Kustomization.

#### 4.3 Security

- Pod Security Admission audit (which namespaces are privileged and why?)
- RBAC scope (any overly broad ClusterRoleBindings?)
- Secret exposure (env vars vs volume mounts, which is safer per component?)
- Network policies (none exist today — assess risk and priority)
- Image references (tags vs digests, mutable vs immutable)

**Tests:** Enumerate all privileged namespaces. Verify no Secrets appear in pod env dumps.

#### 4.4 Best practices

- Terraform patterns against HashiCorp style guide
- Kubernetes patterns against production best practices
- Flux patterns against Flux documentation recommendations
- Helm usage (valuesFrom patterns, CRD management)

**Tests:** `tflint` with additional rulesets. `kubeconform` with strict mode and full CRD coverage.

#### 4.5 Helm chart version audit

- Compare pinned chart versions against latest releases
- Flag charts with known CVEs or breaking changes
- Bitnami chart freeze impact assessment

**Tests:** Script that compares HelmRelease versions against Helm repo latest.

#### 4.6 Final documentation update

- Update `CLAUDE.md`, `ARCHITECTURE.md`, `README.md` to reflect all changes
- Archive or update stale design documents
- Update roadmap status

**Tests:** Re-run documentation accuracy checks from Phase 0.1.
