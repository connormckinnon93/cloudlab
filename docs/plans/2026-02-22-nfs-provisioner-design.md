# NFS Storage Provisioner — Design

## Goal

Enable dynamic PersistentVolume provisioning backed by the Synology NAS, so workloads can request storage through standard PVCs without manual PV creation.

## Approach

Use **nfs-subdir-external-provisioner** — a lightweight Helm chart that creates subdirectories on a single NFS export. Each PVC gets its own subdirectory named `${namespace}-${pvcName}-${pvName}`.

democratic-csi was considered and rejected. It creates separate NFS shares per PV via the Synology API, adding complexity (API tokens, SSH access, driver configuration) for isolation guarantees a single-operator homelab does not need.

**Future migration path:** The Kubernetes ecosystem is moving toward [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs) as the actively maintained replacement. It adds VolumeSnapshot support and active development. nfs-subdir-external-provisioner is in low-maintenance mode (app version unchanged since v4.0.2, chart bumps are metadata only). Migration is not urgent — the provisioner is stable — but csi-driver-nfs is the long-term direction.

**Isolation limitation:** All PVC subdirectories share a single NFS export under `/volume1/kubernetes/`. There is no filesystem-level isolation between PVCs. Any pod that gains access to the parent path could read other PVCs' data. This is an inherent limitation of the subdir provisioner pattern and acceptable for a single-operator homelab.

## Synology Prerequisites (manual)

Create the NFS export on the Synology NAS before deploying to the cluster:

1. **Create shared folder** in DSM Control Panel → Shared Folder:
   - Name: `kubernetes`
   - Location: Volume 1
   - Disable Recycle Bin (Kubernetes manages its own lifecycle)

2. **Enable NFS** in Control Panel → File Services → NFS:
   - Enable NFS service (if not already)
   - Maximum NFS protocol: NFSv4

3. **Set NFS permissions** on the `kubernetes` shared folder:
   - Edit → NFS Permissions → Create:
   - Hostname/IP: `192.168.20.100` (cluster node only — expand if adding worker nodes)
   - Privilege: Read/Write
   - Squash: No mapping (`no_squash`)
   - Security: `sys`
   - Enable async: Yes

The resulting export path: `/volume1/kubernetes`.

**Async tradeoff:** async improves write performance significantly but risks losing up to ~5 seconds of NFS writes if the Synology loses power mid-write. A UPS on the Synology mitigates this. Acceptable for homelab workloads.

4. **Enable BTRFS snapshots** on the `kubernetes` shared folder:
   - Control Panel → Shared Folder → `kubernetes` → Snapshots
   - Schedule periodic snapshots as a safety net against accidental deletion

5. **Enable volume usage alerts** in DSM Storage Manager:
   - Set alert threshold at 80% volume usage
   - NFS does not enforce per-PVC size limits — the Synology volume is the real capacity boundary

This stays manual — one-time physical infrastructure setup that belongs neither in Terraform nor GitOps.

## Kubernetes Deployment

### File Structure

```
kubernetes/infrastructure/
├── kustomization.yaml              # Add nfs-provisioner reference
└── nfs-provisioner/
    ├── namespace.yaml              # Dedicated namespace
    ├── helmrepository.yaml         # Flux HelmRepository source
    ├── helmrelease.yaml            # Flux HelmRelease with chart values
    └── kustomization.yaml          # Kustomize entry point
```

### Architecture

- **Own namespace** (`nfs-provisioner`) — isolates infrastructure from workloads. The same pattern repeats for ingress, cert-manager, and monitoring in later roadmap steps.
- **HelmRepository + HelmRelease** — Flux's native Helm support. Flux watches the upstream chart and reconciles automatically. No vendored tarballs in git.
- **No encrypted secrets** — the NFS server address and export path are not sensitive. Everything lives in plaintext HelmRelease values.

### HelmRelease Values

```yaml
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

**`defaultClass: true`** — only StorageClass in the cluster; any PVC without an explicit `storageClassName` gets NFS automatically.

**`reclaimPolicy: Delete`** + **`archiveOnDelete: true`** — when a PVC is deleted, Kubernetes deletes the PV object (keeping cluster state clean), and the provisioner renames the NFS subdirectory to `archived-*` (preserving data on the NAS). This avoids accumulating orphaned PVs in `Released` state while maintaining a data safety net. Periodically review and clean up `archived-*` directories on the NAS via DSM File Station.

Note: `archiveOnDelete` only fires when `reclaimPolicy: Delete`. With `Retain`, the provisioner's delete handler is never invoked and archiving never occurs. See [kubernetes-sigs/nfs-subdir-external-provisioner#363](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/issues/363).

**`mountOptions`** — `nfsvers=4` pins NFSv4 (matching Synology config, prevents silent fallback to v3). `hard` retries NFS operations indefinitely on server unavailability instead of returning errors (critical for data integrity). `noatime` skips access time updates, reducing NFS traffic.

**`allowVolumeExpansion: true`** — NFS has no quota enforcement, so resize requests succeed trivially. Enabling this prevents confusing errors if a workload tries to resize its PVC.

**`resources`** — the provisioner is lightweight (watches PVC events, creates/renames directories). Modest limits prevent pathological behavior without risking throttling.

**Chart version pinned** in the HelmRelease to prevent surprise upgrades.

## Validation

1. **Flux reconciliation** — confirm HelmRepository resolves and HelmRelease installs cleanly. `mise run check` passes.
2. **StorageClass** — `kubectl get storageclass` shows `nfs` as default.
3. **End-to-end test** — create a temporary PVC and pod:
   - PVC requests storage from the `nfs` StorageClass
   - Pod mounts the volume and writes a file
   - File appears on the NAS at `/volume1/kubernetes/<subdir>/`
   - Delete test resources
   - Subdirectory renamed to `archived-*`, confirming `reclaimPolicy: Delete` + `archiveOnDelete: true`
4. **Cleanup** — remove test PVC and pod. Test manifests are not committed to git.
