# NFS Storage Provisioner — Design

## Goal

Enable dynamic PersistentVolume provisioning backed by the Synology NAS, so workloads can request storage through standard PVCs without manual PV creation.

## Approach

Use **nfs-subdir-external-provisioner** — a lightweight Helm chart that creates subdirectories on a single NFS export. Each PVC gets its own subdirectory named `${namespace}-${pvcName}-${pvName}`.

democratic-csi was considered and rejected. It creates separate NFS shares per PV via the Synology API, adding complexity (API tokens, SSH access, driver configuration) for isolation guarantees a single-operator homelab does not need.

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
   - Hostname/IP: `192.168.20.0/24`
   - Privilege: Read/Write
   - Squash: No mapping (`no_squash`)
   - Security: `sys`
   - Enable async: Yes

The resulting export path: `/volume1/kubernetes`.

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

storageClass:
  name: nfs
  defaultClass: true
  reclaimPolicy: Retain
  archiveOnDelete: true

replicaCount: 1
```

**`defaultClass: true`** — only StorageClass in the cluster; any PVC without an explicit `storageClassName` gets NFS automatically.

**`reclaimPolicy: Retain`** — PV data survives PVC deletion. Accidental `kubectl delete pvc` should not mean data loss. Clean up manually on the NAS when needed.

**`archiveOnDelete: true`** — when a PV is released, the provisioner renames the subdirectory to `archived-*` instead of deleting it. Belt-and-suspenders with Retain.

**Chart version pinned** in the HelmRelease to prevent surprise upgrades.

## Validation

1. **Flux reconciliation** — confirm HelmRepository resolves and HelmRelease installs cleanly. `mise run check` passes.
2. **StorageClass** — `kubectl get storageclass` shows `nfs` as default.
3. **End-to-end test** — create a temporary PVC and pod:
   - PVC requests storage from the `nfs` StorageClass
   - Pod mounts the volume and writes a file
   - File appears on the NAS at `/volume1/kubernetes/<subdir>/`
   - Delete test resources
   - Subdirectory renamed to `archived-*`, confirming Retain + archiveOnDelete
4. **Cleanup** — remove test PVC and pod. Test manifests are not committed to git.
