# Kyverno Image Verification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Kyverno via Flux HelmRelease with an image signature verification ClusterPolicy in audit mode, scoped to GHCR images signed via GitHub Actions.

**Architecture:** Four Kyverno controller Deployments installed via Helm into a dedicated namespace. A single ClusterPolicy verifies GHCR images (Flux, Kyverno) against Sigstore's keyless signing infrastructure. Audit mode logs violations without blocking unverified images. System namespaces are excluded.

**Tech Stack:** Kyverno 3.7.1 (Helm chart), Flux CD (HelmRepository + HelmRelease), Kustomize, Sigstore Rekor

---

### Task 1: Create Kyverno namespace and Helm source

**Files:**
- Create: `kubernetes/infrastructure/kyverno/namespace.yaml`
- Create: `kubernetes/infrastructure/kyverno/helmrepository.yaml`

**Step 1: Create namespace.yaml**

Follow the nfs-provisioner pattern at `kubernetes/infrastructure/nfs-provisioner/namespace.yaml`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kyverno
```

**Step 2: Create helmrepository.yaml**

Follow the nfs-provisioner pattern at `kubernetes/infrastructure/nfs-provisioner/helmrepository.yaml`.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: kyverno
  namespace: kyverno
spec:
  interval: 60m
  url: https://kyverno.github.io/kyverno/
```

---

### Task 2: Create Kyverno HelmRelease

**Files:**
- Create: `kubernetes/infrastructure/kyverno/helmrelease.yaml`

**Step 1: Create helmrelease.yaml**

Follow the nfs-provisioner pattern at `kubernetes/infrastructure/nfs-provisioner/helmrelease.yaml`. Use chart name `kyverno`, version `3.7.1`. Resource limits from the design doc. Note: `admissionController` nests resources under `container`, while the other three controllers have `resources` at the top level.

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kyverno
  namespace: kyverno
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: kyverno
      version: "3.7.1"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: kyverno
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    admissionController:
      replicas: 1
      container:
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 384Mi
    backgroundController:
      resources:
        requests:
          cpu: 25m
          memory: 64Mi
        limits:
          memory: 256Mi
    cleanupController:
      resources:
        requests:
          cpu: 25m
          memory: 64Mi
        limits:
          memory: 128Mi
    reportsController:
      resources:
        requests:
          cpu: 25m
          memory: 64Mi
        limits:
          memory: 256Mi
```

---

### Task 3: Create image verification ClusterPolicy

**Files:**
- Create: `kubernetes/infrastructure/kyverno/clusterpolicy-verify-images.yaml`

**Step 1: Create clusterpolicy-verify-images.yaml**

From the design doc. Audit mode, GHCR image scope (Flux and Kyverno images signed via GitHub Actions), namespace exclusions for `kube-system` and `kyverno`, Sigstore keyless verification via Rekor. Uses modern Kyverno 1.13+ syntax: `failureAction` per-rule instead of deprecated `validationFailureAction`, `webhookConfiguration.timeoutSeconds` instead of deprecated `webhookTimeoutSeconds`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  webhookConfiguration:
    timeoutSeconds: 30
  rules:
    - name: verify-sigstore-keyless
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      verifyImages:
        - imageReferences:
            - "ghcr.io/fluxcd/*"
            - "ghcr.io/kyverno/*"
          failureAction: Audit
          attestors:
            - entries:
                - keyless:
                    issuerRegExp: "https://token\\.actions\\.githubusercontent\\..*"
                    subjectRegExp: "https://github\\.com/.+"
                    rekor:
                      url: https://rekor.sigstore.dev
```

---

### Task 4: Wire up Kustomize, validate, and commit

**Files:**
- Create: `kubernetes/infrastructure/kyverno/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create kyverno/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
  - clusterpolicy-verify-images.yaml
```

**Step 2: Add kyverno to infrastructure kustomization.yaml**

Edit `kubernetes/infrastructure/kustomization.yaml` — add `- kyverno` to the resources list (after `nfs-provisioner`).

**Step 3: Run validation**

Run: `mise run check`
Expected: All checks pass. Kyverno manifests appear in the `kubernetes/infrastructure/` kubeconform output.

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/kyverno/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(kyverno): add kyverno with image verification policy"
```

---

### Task 5: Update roadmap in README.md

**Files:**
- Modify: `README.md` (lines 87-150, Roadmap section)

**Step 1: Update intro line**

Change:
```
Thirty steps in six phases.
```
to:
```
Thirty-one steps in six phases.
```

(Removing 1 step, adding 2 = net +1, from 30 to 31.)

**Step 2: Strike through step 11 (Kyverno)**

Change:
```
11. **Kyverno** — Image signature verification first, general policies later
```
to:
```
11. ~~**Kyverno** — Image signature verification first, general policies later~~
```

**Step 3: Remove step 12 and renumber Phase 2**

Delete the etcd backups line:
```
12. **etcd backups** — Periodic `talosctl etcd snapshot` to Synology NAS (Proxmox VM backups cover the gap until here)
```

Renumber the remaining Phase 2 items. The full Phase 2 after changes:
```
9. **Log aggregation** — Loki + Promtail for centralized container logs alongside Prometheus metrics
10. **Alerting** — Alertmanager with notifications to Pushover, Discord, or similar
11. ~~**Kyverno** — Image signature verification first, general policies later~~
12. **Authentication gateway** — Single sign-on and 2FA in front of all services
13. **Gitea/Forgejo** — First self-hosted app; migrate Flux source from GitHub
14. **Renovate** — Automated dependency updates (against Gitea)
15. **Infisical** — Self-hosted secrets management; begin migrating from SOPS
```

**Step 4: Renumber Phase 3 and insert Kyverno hardening items**

Insert two new items after Network policies (now step 17). The full Phase 3 after changes:
```
16. **Remote access** — Tailscale for secure access from outside the home network
17. **Network policies** — Cilium policies to isolate namespaces and restrict traffic
18. **Kyverno enforce mode** — Migrate image verification from audit to enforce
19. **Kyverno general policies** — Disallow privileged containers, require resource limits, disallow `latest` tag
20. **Multi-node expansion** — Add worker node(s); refactor Terraform with `for_each`
21. **Automated cluster upgrades** — Formalize TalosOS and Kubernetes upgrade workflow
22. **Remote Terraform state** — S3-compatible backend on Synology for state locking
```

**Step 5: Renumber Phases 4-6**

Phase 4:
```
23. **Hubble observability** — Cilium's service map and flow visibility via eBPF
24. **PersistentVolume backups** — Volsync for scheduled PVC replication to NAS
25. **Cluster dashboard** — Headlamp for visual cluster inspection behind auth
```

Phase 5:
```
26. **Gateway API migration** — Move from Ingress resources to HTTPRoute/Gateway
27. **Image pull-through cache** — Spegel for peer-to-peer registry mirroring on-cluster
28. **Descheduler** — Evict pods that violate scheduling constraints over time
```

Phase 6:
```
29. **Chaos testing** — Break things on purpose; verify alerts fire and recovery works
30. **Resource quotas** — Per-namespace CPU/memory limits to prevent resource starvation
31. **GitOps repo refactor** — Kustomize base/overlays structure for multi-cluster readiness
```

**Step 6: Update Decisions table**

Renumber the Auth architecture decision from step 13 to step 12, VCS platform from 14 to 13, Secrets manager from 16 to 15.

**Step 7: Commit**

```bash
git add README.md
git commit -m "docs: update roadmap for kyverno and remove etcd backups"
```

---

### Task 6: Update CLAUDE.md and final validation

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add kyverno to Key Files table**

Add after the `nfs-provisioner` row:
```
| `kubernetes/infrastructure/kyverno/` | Kyverno policy engine (Flux HelmRelease) |
```

**Step 2: Add implementation note for Kyverno**

Add to the Implementation Notes section:
```
- **Kyverno image verification**: The ClusterPolicy verifies GHCR images (`ghcr.io/fluxcd/*`, `ghcr.io/kyverno/*`) in audit mode — unverified images are admitted but violations appear in PolicyReports (`kubectl get policyreport -A`). System namespaces (`kube-system`, `kyverno`) are excluded. Migrating to enforce mode requires reviewing audit results and potentially adding attestor entries for other signing authorities.
```

**Step 3: Run final validation**

Run: `mise run check`
Expected: All checks pass.

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add kyverno to CLAUDE.md"
```
