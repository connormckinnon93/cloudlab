# NFS Storage Provisioner — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy nfs-subdir-external-provisioner via Flux so workloads get dynamic NFS-backed PersistentVolumes through standard PVCs.

**Architecture:** Four Kubernetes manifests in a dedicated `nfs-provisioner/` directory under `kubernetes/infrastructure/`, wired into the existing Flux Kustomization hierarchy. Flux reconciles the HelmRelease, which deploys the provisioner pointing at the Synology NAS export.

**Tech Stack:** Flux CD (HelmRepository + HelmRelease), nfs-subdir-external-provisioner Helm chart, Kustomize

**Design:** `docs/plans/2026-02-22-nfs-provisioner-design.md`

---

## Planning Notes

**Discovery: Chart version.** The latest nfs-subdir-external-provisioner chart version is 4.0.18 (from the kubernetes-sigs Helm repository). Pinned exactly to prevent surprise upgrades.

**Discovery: Flux API versions.** Flux 2.7 (installed in this cluster) uses GA APIs: `source.toolkit.fluxcd.io/v1` for HelmRepository and `helm.toolkit.fluxcd.io/v2` for HelmRelease.

**Discovery: NFS utils already configured.** TalosOS is provisioned with the `nfs-utils` system extension (see `terraform/talos.tf`). No Terraform changes needed.

**Discovery: Validation approach.** No unit test framework for Kubernetes manifests. Validation is `mise run check`, which runs `kustomize build kubernetes/infrastructure/ | kubeconform`. Flux CRDs (HelmRepository, HelmRelease) lack kubeconform schemas and are skipped via `-ignore-missing-schemas`. The Namespace resource is validated strictly.

**Discovery: Namespace ordering.** Flux's kustomize-controller applies Namespaces before namespaced resources. The `nfs-provisioner` Namespace will exist before the HelmRepository and HelmRelease are created. No `createNamespace` needed on the HelmRelease.

**Prerequisite: Synology NAS.** The NFS export (`/volume1/kubernetes` on `192.168.20.20`) must exist before Task 2. Follow the manual Synology setup in the design doc if not already done.

---

### Task 1: Create nfs-provisioner manifests and validate locally

**Files:**
- Create: `kubernetes/infrastructure/nfs-provisioner/namespace.yaml`
- Create: `kubernetes/infrastructure/nfs-provisioner/helmrepository.yaml`
- Create: `kubernetes/infrastructure/nfs-provisioner/helmrelease.yaml`
- Create: `kubernetes/infrastructure/nfs-provisioner/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create the nfs-provisioner directory**

```bash
mkdir -p kubernetes/infrastructure/nfs-provisioner
```

**Step 2: Write `namespace.yaml`**

Create `kubernetes/infrastructure/nfs-provisioner/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nfs-provisioner
```

**Step 3: Write `helmrepository.yaml`**

Create `kubernetes/infrastructure/nfs-provisioner/helmrepository.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nfs-provisioner
  namespace: nfs-provisioner
spec:
  interval: 60m
  url: https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
```

`interval: 60m` — chart repos change infrequently.

**Step 4: Write `helmrelease.yaml`**

Create `kubernetes/infrastructure/nfs-provisioner/helmrelease.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nfs-provisioner
  namespace: nfs-provisioner
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: nfs-subdir-external-provisioner
      version: "4.0.18"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: nfs-provisioner
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    nfs:
      server: 192.168.20.20
      path: /volume1/kubernetes
      mountOptions:
        - nfsvers=4
        - hard
        - noatime
    storageClass:
      name: nfs
      defaultClass: true
      reclaimPolicy: Delete
      archiveOnDelete: true
      allowVolumeExpansion: true
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        memory: 128Mi
    replicaCount: 1
```

**Step 5: Write the component `kustomization.yaml`**

Create `kubernetes/infrastructure/nfs-provisioner/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
```

**Step 6: Wire into infrastructure**

Update `kubernetes/infrastructure/kustomization.yaml` — replace the empty resources list:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - nfs-provisioner
```

**Step 7: Validate locally**

Run: `mise run check`

Expected: All sections pass. `kubernetes/infrastructure/` builds cleanly — the Namespace validates strictly, the Flux CRDs pass with `-ignore-missing-schemas`.

If kustomize build fails, check that `kustomization.yaml` resource paths match the filenames exactly.

**Step 8: Commit**

```bash
git add kubernetes/infrastructure/
git commit -m "feat(nfs): add nfs-subdir-external-provisioner manifests"
```

---

### Task 2: Push and verify Flux reconciliation

**Files:** None — git and kubectl operations only

**Prerequisite:** Synology NAS export `/volume1/kubernetes` exists and is accessible from `192.168.20.100`. Follow the design doc's Synology Prerequisites section if not done.

**Step 1: Push**

```bash
git push
```

**Step 2: Wait for Flux to reconcile**

Run: `flux reconcile kustomization infrastructure --with-source`

This forces immediate reconciliation instead of waiting for the 10m interval. The `--with-source` flag also refreshes the GitRepository.

**Step 3: Verify the infrastructure Kustomization is healthy**

Run: `flux get kustomizations`

Expected: `infrastructure` shows `Ready` with `True` status. If it shows `False`, check the message for details.

**Step 4: Verify the HelmRelease installed**

Run: `flux get helmreleases -n nfs-provisioner`

Expected: `nfs-provisioner` shows `Ready` with `True` and the installed chart version `4.0.18`.

If the HelmRelease is not ready, debug with:

```bash
flux events -n nfs-provisioner
kubectl describe helmrelease nfs-provisioner -n nfs-provisioner
```

Common failures: NFS server unreachable (check Synology), chart version not found (check HelmRepository URL).

**Step 5: Verify the StorageClass**

Run: `kubectl get storageclass`

Expected: `nfs` appears with `(default)` annotation. It should be the only StorageClass unless Talos added one.

**Step 6: Verify the provisioner pod is running**

Run: `kubectl get pods -n nfs-provisioner`

Expected: One pod with status `Running`.

---

### Task 3: End-to-end storage test

**Files:** None — kubectl operations only. Test manifests are applied directly, not committed to git.

**Step 1: Create a test PVC**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-claim
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
EOF
```

**Step 2: Verify the PVC is bound**

Run: `kubectl get pvc test-nfs-claim`

Expected: Status is `Bound`. If `Pending`, check provisioner logs: `kubectl logs -n nfs-provisioner -l app=nfs-subdir-external-provisioner`

**Step 3: Create a test pod that writes to the volume**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-nfs-pod
  namespace: default
spec:
  containers:
    - name: test
      image: busybox
      command: ["sh", "-c", "echo 'nfs-provisioner works' > /mnt/test.txt && sleep 3600"]
      volumeMounts:
        - name: nfs-vol
          mountPath: /mnt
  volumes:
    - name: nfs-vol
      persistentVolumeClaim:
        claimName: test-nfs-claim
EOF
```

**Step 4: Wait for the pod to be running**

Run: `kubectl wait --for=condition=Ready pod/test-nfs-pod --timeout=60s`

**Step 5: Verify the file was written**

Run: `kubectl exec test-nfs-pod -- cat /mnt/test.txt`

Expected: `nfs-provisioner works`

**Step 6: Verify the subdirectory exists on the NAS**

The provisioner creates a subdirectory named `${namespace}-${pvcName}-${pvName}` under `/volume1/kubernetes/`. Confirm via the Synology DSM file browser or SSH that the directory and `test.txt` exist.

**Step 7: Delete test resources**

```bash
kubectl delete pod test-nfs-pod
kubectl delete pvc test-nfs-claim
```

**Step 8: Verify archive behavior**

On the NAS, the subdirectory should now be renamed to `archived-default-test-nfs-claim-<pvName>`. This confirms `reclaimPolicy: Delete` + `archiveOnDelete: true` — Kubernetes deleted the PV object, and the provisioner archived the directory instead of removing it.

---

### Task 4: Update documentation

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add NFS provisioner to Key Files table in `CLAUDE.md`**

Add a row to the Key Files table:

```
| `kubernetes/infrastructure/nfs-provisioner/` | NFS dynamic volume provisioner (Flux HelmRelease) |
```

**Step 2: Add implementation note to `CLAUDE.md`**

Add to the Implementation Notes section:

```
- **NFS provisioner pattern**: Infrastructure components follow a consistent directory structure under `kubernetes/infrastructure/`: dedicated namespace, HelmRepository, HelmRelease, and a Kustomize entry point. The parent `infrastructure/kustomization.yaml` references each component by directory name. This pattern repeats for ingress, cert-manager, and monitoring.
```

**Step 3: Validate and commit**

Run: `mise run check`

```bash
git add CLAUDE.md
git commit -m "docs: add nfs-provisioner to CLAUDE.md"
git push
```
