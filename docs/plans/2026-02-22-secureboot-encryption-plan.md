# SecureBoot + Disk Encryption Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable UEFI SecureBoot and TPM-sealed LUKS2 disk encryption on the TalosOS VM.

**Architecture:** Add SecureBoot firmware settings (EFI type, virtual TPM) to the VM resource, switch to SecureBoot ISO and installer images, and add VolumeConfig patches for LUKS2 encryption on both STATE and EPHEMERAL partitions. All changes destroy and recreate the VM — safe because no workloads exist yet.

**Tech Stack:** Terraform (HCL), TalosOS VolumeConfig, Proxmox bpg provider

**Design:** `docs/plans/2026-02-22-secureboot-encryption-design.md`

---

## Planning Notes

**Discovery:** The `talos:upgrade` task in `.mise.toml:74` uses `installer` in its image path. After SecureBoot is enabled, future upgrades must use `installer-secureboot`. The design doc doesn't mention this, but leaving it unchanged would cause upgrade failures. Added as Task 5.

**Testing approach:** This is infrastructure code with no unit test framework. Validation is `mise run check` (fmt + validate + lint) after each code change, and `mise run tf plan` as the final integration check.

---

### Task 1: Configure EFI disk and virtual TPM

**Files:**
- Modify: `terraform/main.tf:60-62` (efi_disk block)
- Modify: `terraform/main.tf:62` (insert tpm_state after efi_disk)

**Step 1: Add `type` and `pre_enrolled_keys` to the `efi_disk` block**

Replace the existing `efi_disk` block at line 60-62:

```hcl
  efi_disk {
    datastore_id      = "local-lvm"
    type              = "4m"
    pre_enrolled_keys = false
  }
```

`type = "4m"` selects the OVMF 4MB firmware (required for SecureBoot). `pre_enrolled_keys = false` leaves UEFI in setup mode so Talos can enroll Sidero Labs keys on first boot.

**Step 2: Add `tpm_state` block after `efi_disk`**

Insert between the `efi_disk` closing brace and the `disk` block:

```hcl
  tpm_state {
    version = "v2.0"
  }
```

The virtual TPM seals LUKS2 keys to the VM's boot chain PCR measurements.

**Step 3: Validate**

Run: `mise run check`
Expected: All three checks pass (fmt, validate, lint). No errors.

**Step 4: Commit**

```bash
git add terraform/main.tf
git commit -m "feat(vm): add SecureBoot EFI type and virtual TPM"
```

---

### Task 2: Switch to SecureBoot ISO

**Files:**
- Modify: `terraform/main.tf:29-30` (image URL and file_name)

**Step 1: Change image URL and filename to SecureBoot variant**

At line 29, change `metal-amd64.iso` to `metal-amd64-secureboot.iso` in both the `url` and `file_name` attributes:

```hcl
  url       = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64-secureboot.iso"
  file_name = "talos-${var.talos_version}-metal-amd64-secureboot.iso"
```

The schematic ID is unchanged — the factory produces both variants from the same schematic.

**Step 2: Validate**

Run: `mise run check`
Expected: All checks pass.

**Step 3: Commit**

```bash
git add terraform/main.tf
git commit -m "feat(vm): switch to SecureBoot ISO image"
```

---

### Task 3: Switch to SecureBoot installer

**Files:**
- Modify: `terraform/talos.tf:51` (installer image path)

**Step 1: Change installer path from `installer` to `installer-secureboot`**

At line 51, change:

```hcl
          image = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}"
```

to:

```hcl
          image = "factory.talos.dev/installer-secureboot/${var.talos_schematic_id}:${var.talos_version}"
```

**Step 2: Validate**

Run: `mise run check`
Expected: All checks pass.

**Step 3: Commit**

```bash
git add terraform/talos.tf
git commit -m "feat(talos): switch to SecureBoot installer image"
```

---

### Task 4: Add disk encryption patches

**Files:**
- Modify: `terraform/talos.tf:46-89` (config_patches list)

**Step 1: Add STATE and EPHEMERAL VolumeConfig patches**

Append two new `yamlencode()` entries to the `config_patches` list, after the existing HostnameConfig entry (line 88). Insert before the closing `]` on line 89:

```hcl
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "VolumeConfig"
      name       = "STATE"
      encryption = {
        provider = "luks2"
        keys = [{
          tpm  = {}
          slot = 0
        }]
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "VolumeConfig"
      name       = "EPHEMERAL"
      encryption = {
        provider = "luks2"
        keys = [{
          tpm  = {}
          slot = 0
        }]
      }
    }),
```

This follows the same multi-doc pattern as the existing `HostnameConfig` patch. Both STATE (machine config, etcd) and EPHEMERAL (container storage) partitions get LUKS2 encryption sealed to the TPM.

**Step 2: Validate**

Run: `mise run check`
Expected: All checks pass.

**Step 3: Commit**

```bash
git add terraform/talos.tf
git commit -m "feat(talos): add LUKS2 disk encryption for STATE and EPHEMERAL"
```

---

### Task 5: Update talos:upgrade task for SecureBoot

**Files:**
- Modify: `.mise.toml:74` (upgrade task run command)

**Context:** This was not in the design doc but is necessary for correctness. The existing `talos:upgrade` task uses `installer` in its image path. After SecureBoot, upgrades must use `installer-secureboot` or they will fail.

**Step 1: Change installer to installer-secureboot in the upgrade task**

At line 74, change:

```toml
run = "talosctl upgrade --image factory.talos.dev/installer/${usage_schematic_id?}:${usage_version?} --preserve"
```

to:

```toml
run = "talosctl upgrade --image factory.talos.dev/installer-secureboot/${usage_schematic_id?}:${usage_version?} --preserve"
```

**Step 2: Commit**

```bash
git add .mise.toml
git commit -m "fix(mise): use SecureBoot installer in talos:upgrade task"
```

---

### Task 6: Reorder roadmap in README

**Files:**
- Modify: `README.md:94-106` (Phase 1 roadmap)

**Step 1: Replace Phase 1 list**

Merge steps 1 and 2 into "SecureBoot + disk encryption". Move etcd backups from step 10 to step 2 (safety net before workloads). Renumber remaining steps.

Replace the Phase 1 list (lines 96-105) with:

```markdown
1. **SecureBoot + disk encryption** — EFI SecureBoot, virtual TPM, LUKS2 on STATE and EPHEMERAL partitions
2. **etcd backups** — Periodic `talosctl etcd snapshot` to Synology NAS
3. **Bootstrap Flux** — GitOps foundation; subsequent steps deploy as git commits
4. **SOPS + Flux** — Decrypt SOPS-encrypted secrets in-cluster via Flux's kustomize-controller
5. **NFS storage provisioner** — Dynamic PersistentVolumes backed by Synology NAS
6. **Ingress controller** — Route external HTTP/HTTPS traffic to cluster services
7. **cert-manager** — Automated TLS certificates via Let's Encrypt
8. **Internal DNS** — Resolve friendly service names to the ingress IP
9. **Monitoring** — Prometheus + Grafana for metrics, dashboards, and cluster health
```

**Step 2: Update roadmap summary line**

Change line 80 from "Thirty steps" to "Twenty-nine steps":

```markdown
Twenty-nine steps in six phases. Each step is self-contained; dependency order is respected within phases.
```

**Step 3: Update the decisions table**

The step numbers in the decisions table (lines 88-93) shift because etcd backups moved to step 2. All referenced steps stay the same (Flux is now 3, NFS is 5, Ingress is 6, Internal DNS is 8, Auth is still 14) — but verify the step numbers match:

| Decision | Step | Current |
|----------|------|---------|
| Flux repo structure | 3 | Was 3, unchanged |
| Ingress approach | 6 | Was 6, unchanged |
| Service domain | 8 | Was 8, unchanged |
| NFS provisioner | 5 | Was 5, unchanged |
| Auth architecture | 14 | Was 14, unchanged |

No changes needed in the decisions table — the step numbers happen to remain the same because the merge and reorder cancel out within Phase 1.

**Step 4: Update CLAUDE.md platform note about SecureBoot**

In `CLAUDE.md`, the platform notes say "SecureBoot currently disabled — see roadmap step 1". After this work, SecureBoot is enabled. Update to:

```
TalosOS v1.12.4 (SecureBoot + TPM-sealed LUKS2 encryption), extensions: qemu-guest-agent, nfs-utils
```

**Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: reorder roadmap, update SecureBoot status"
```

---

### Task 7: Final validation

**Step 1: Run full lint check**

Run: `mise run check`
Expected: All checks pass.

**Step 2: Run terraform plan**

Run: `mise run tf plan`
Expected: Plan shows destroy + recreate of `proxmox_virtual_environment_vm.talos` and `proxmox_virtual_environment_download_file.talos_image` (new ISO filename), plus tainted/replaced Talos resources that depend on the VM. No unexpected changes.

**Step 3: Review the plan output**

Verify:
- VM resource shows `efi_disk.type = "4m"`, `efi_disk.pre_enrolled_keys = false`
- New `tpm_state` block with `version = "v2.0"`
- ISO URL ends in `metal-amd64-secureboot.iso`
- Installer image uses `installer-secureboot`
- Config patches include STATE and EPHEMERAL VolumeConfig entries

Do **not** apply yet — applying destroys the running VM.
