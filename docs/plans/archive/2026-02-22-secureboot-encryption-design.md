# SecureBoot + Disk Encryption — Design

## Goal

Enable UEFI SecureBoot and TPM-sealed LUKS2 disk encryption on the TalosOS VM. Both changes require destroying and recreating the VM, so they belong in a single operation. The cluster has no workloads yet.

## Changes

### 1. EFI disk (main.tf)

Add `type` and `pre_enrolled_keys` to the existing `efi_disk` block:

```hcl
efi_disk {
  datastore_id      = "local-lvm"
  type              = "4m"
  pre_enrolled_keys = false
}
```

`pre_enrolled_keys = false` leaves the UEFI firmware in setup mode. The Talos SecureBoot ISO enrolls the Sidero Labs signing keys automatically on first boot. Pre-enrolling Microsoft keys would block this.

### 2. Virtual TPM (main.tf)

Add a `tpm_state` block to the VM resource:

```hcl
tpm_state {
  datastore_id = "local-lvm"
  version      = "v2.0"
}
```

Explicit `datastore_id` matches the `efi_disk` block's style. The virtual TPM seals the LUKS2 encryption keys to the VM's boot chain measurements (PCR values). The disk can only be decrypted on this specific VM with this specific TPM state.

### 3. SecureBoot ISO (main.tf)

Change the image URL from `metal-amd64.iso` to `metal-amd64-secureboot.iso`:

```
https://factory.talos.dev/image/<schematic>/<version>/metal-amd64-secureboot.iso
```

The schematic ID stays the same; the factory produces both variants from it.

### 4. SecureBoot installer (talos.tf)

Change the installer image path from `installer` to `installer-secureboot` in the machine config patch:

```
factory.talos.dev/installer-secureboot/<schematic>:<version>
```

### 5. Disk encryption patches (talos.tf)

Add two new `yamlencode()` entries to the `config_patches` list in `talos_machine_configuration_apply`:

```yaml
apiVersion: v1alpha1
kind: VolumeConfig
name: STATE
encryption:
  provider: luks2
  keys:
    - tpm:
        checkSecurebootStatusOnEnroll: true
      slot: 0
```

```yaml
apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
encryption:
  provider: luks2
  keys:
    - tpm:
        checkSecurebootStatusOnEnroll: true
      slot: 0
      lockToState: true
```

This uses the multi-doc `VolumeConfig` format, consistent with the existing `HostnameConfig` patch. Both STATE (machine config, etcd data) and EPHEMERAL (container storage) partitions are encrypted. `checkSecurebootStatusOnEnroll` fails key enrollment if SecureBoot is not active, coupling the two security features. `lockToState` on EPHEMERAL binds its key to the STATE partition's random salt, as recommended by Talos docs for non-STATE volumes.

### 6. Roadmap reorder (README.md)

Merge steps 1 and 2 into a single step. Move etcd backups to step 2 (before Flux, so the safety net exists before workloads arrive). Renumber all subsequent steps — Phase 1 changes and every step in Phases 2-6 shifts down by one. Phase 1 becomes:

1. SecureBoot + disk encryption
2. etcd backups
3. Bootstrap Flux
4. SOPS + Flux
5. NFS storage provisioner
6. Ingress controller
7. cert-manager
8. Internal DNS
9. Monitoring

Total steps drop from 30 to 29. The decisions table must also update: Auth architecture moves from step 14 to step 13.

## Out of Scope

- **Schematic ID** — same extensions (qemu-guest-agent, nfs-mount), unchanged
- **Cipher or block size overrides** — Talos defaults (aes-xts-plain64, 4096) suffice
- **PCR policy customization** — default TPM PCR sealing is sufficient
- **Custom SecureBoot keys** — Sidero Labs-signed images, not self-signed
- **Talos version bump** — staying on v1.12.4
- **Existing config patches** — network, kubelet, and hostname patches unchanged

## Recovery Considerations

Recreating the VM produces a new virtual TPM, which makes old encrypted disks unrecoverable. This is the same outcome as nodeID-based encryption (new VM means new UUID). Since Terraform destroys and recreates disks anyway, there is nothing to recover from.

The real mitigation is backups. etcd snapshots (roadmap step 2, now prioritized before Flux) protect cluster state. PV backups via Volsync (roadmap step 23) protect workload data later.

Normal Talos upgrades re-seal TPM keys to the new boot measurements automatically.

## Workflow

After applying these changes:

```bash
mise run tf plan    # Expect: destroy + recreate VM, re-bootstrap
mise run tf apply   # Provision SecureBoot VM with encrypted disks
mise run config:export   # Re-encrypt talosconfig and kubeconfig
mise run config:decrypt  # Decrypt for local use
kubectl get nodes        # Verify
```
