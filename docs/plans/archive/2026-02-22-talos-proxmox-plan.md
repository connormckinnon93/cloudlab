# TalosOS on Proxmox — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Provision a single TalosOS VM on Proxmox, bootstrap a single-node Kubernetes cluster, and store encrypted configs in git.

**Architecture:** Terraform creates a Proxmox VM from a TalosOS image downloaded via factory.talos.dev, then uses the Talos provider to generate machine configs, apply them, bootstrap etcd, and retrieve kubeconfig. SOPS with age encrypts all secrets at rest. Mise manages tool versions and task orchestration.

**Tech Stack:** Terraform 1.14, bpg/proxmox provider ~> 0.96, siderolabs/talos provider ~> 0.10, carlpett/sops provider ~> 1.3, SOPS 3.11, age 1.3, tflint 0.61, lefthook 2.1, gitleaks 8.30

---

### Prerequisites (manual)

Before starting, complete these steps:

1. Initialize the git repository: `git init`
2. Generate an age keypair: `age-keygen -o .age-key.txt`
3. Copy the public key from the output (starts with `age1...`)
4. Back up `.age-key.txt` to 1Password

The public key is needed for Task 2 (`.sops.yaml`).

---

### Task 1: Create .gitignore and .gitleaks.toml

**Files:**
- Create: `.gitignore`
- Create: `.gitleaks.toml`

**Step 1: Write .gitignore**

```gitignore
# Age private key
.age-key.txt

# Terraform
terraform/.terraform/
terraform/terraform.tfstate
terraform/*.tfvars
terraform/*.tfvars.json
terraform/*.tfplan
terraform/terraform.tfstate.backup
terraform/crash.log
terraform/override.tf
terraform/override.tf.json
terraform/*_override.tf
terraform/*_override.tf.json

# Claude Code local settings
.claude/settings.local.json

# Decrypted output (encrypted versions are tracked)
terraform/output/talosconfig.yaml
terraform/output/kubeconfig.yaml
```

**Step 2: Write .gitleaks.toml**

```toml
[[rules]]
id = "age-secret-key"
description = "age private key"
regex = '''AGE-SECRET-KEY-[A-Z0-9]+'''
```

**Step 3: Commit**

```bash
git add .gitignore .gitleaks.toml
git commit -m "chore: add .gitignore and custom gitleaks rules"
```

---

### Task 2: Create .sops.yaml

**Files:**
- Create: `.sops.yaml`

**Step 1: Write SOPS config**

The `age` public key placeholder must be replaced by the user after generating their keypair with `age-keygen -o .age-key.txt`.

```yaml
creation_rules:
  - path_regex: '\.enc\.(json|yaml)$'
    age: "age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

**Step 2: Commit**

```bash
git add .sops.yaml
git commit -m "chore: add SOPS encryption rules for age backend"
```

---

### Task 3: Create .mise.toml

**Files:**
- Create: `.mise.toml`

**Step 1: Write Mise config with tool versions and tasks**

```toml
[tools]
terraform = "1.14"
talosctl = "1.12"
sops = "3.11"
age = "1.3"
kubectl = "1.32"
tflint = "0.61"
lefthook = "2.1"
gitleaks = "8.30"

[env]
SOPS_AGE_KEY_FILE = "{{config_root}}/.age-key.txt"

[tasks.setup]
description = "Install tools, initialize tflint, install lefthook"
run = """
mise install
cd terraform && tflint --init && terraform init
lefthook install
"""

[tasks."tf:init"]
description = "Initialize Terraform providers"
dir = "terraform"
run = "terraform init"

[tasks."tf:plan"]
description = "Preview Terraform changes"
dir = "terraform"
usage = 'arg "[extra]" var=#true help="Extra arguments to pass to terraform plan"'
run = "terraform plan ${usage_extra:-}"

[tasks."tf:apply"]
description = "Apply Terraform and encrypt outputs"
dir = "terraform"
usage = 'arg "[extra]" var=#true help="Extra arguments to pass to terraform apply"'
run = """
terraform apply ${usage_extra:-}
mise run tf:export-configs
"""

[tasks."tf:check"]
description = "Run fmt check, validate, and tflint"
dir = "terraform"
run = """
terraform fmt -check
terraform validate
tflint
"""

[tasks."tf:destroy"]
description = "Destroy all Terraform-managed infrastructure"
dir = "terraform"
usage = 'arg "[extra]" var=#true help="Extra arguments to pass to terraform destroy"'
run = "terraform destroy ${usage_extra:-}"

[tasks."tf:output"]
description = "Show Terraform outputs"
dir = "terraform"
usage = 'arg "[extra]" var=#true help="Extra arguments to pass to terraform output"'
run = "terraform output ${usage_extra:-}"

[tasks."tf:state"]
description = "List Terraform state resources"
dir = "terraform"
run = "terraform state list"

[tasks."tf:export-configs"]
description = "Extract and encrypt talosconfig and kubeconfig"
dir = "terraform"
run = """
set -e
mkdir -p output
terraform output -raw talosconfig > output/talosconfig.enc.yaml
sops encrypt -i output/talosconfig.enc.yaml
terraform output -raw kubeconfig > output/kubeconfig.enc.yaml
sops encrypt -i output/kubeconfig.enc.yaml
"""

[tasks."tf:use-configs"]
description = "Decrypt configs to ~/.talos and ~/.kube"
run = """
mkdir -p ~/.talos ~/.kube
sops decrypt terraform/output/talosconfig.enc.yaml > ~/.talos/config
sops decrypt terraform/output/kubeconfig.enc.yaml > ~/.kube/config
"""

[tasks."sops:edit"]
description = "Decrypt, edit, and re-encrypt secrets"
usage = 'arg "[file]" help="File to edit" default="terraform/secrets.enc.json"'
run = "sops ${usage_file?}"

[tasks."talos:upgrade"]
description = "Upgrade TalosOS to a new version"
run = "talosctl upgrade --image factory.talos.dev/installer/{{arg(name='schematic_id')}}:{{arg(name='version')}} --preserve"
```

**Step 2: Commit**

```bash
git add .mise.toml
git commit -m "chore: add Mise tool versions and task definitions"
```

---

### Task 4: Create lefthook.yml

**Files:**
- Create: `lefthook.yml`

**Step 1: Write lefthook config**

```yaml
pre-commit:
  commands:
    fmt-check:
      glob: "terraform/*.tf"
      run: cd terraform && terraform fmt -check
    validate:
      glob: "terraform/*.tf"
      run: cd terraform && terraform validate
    lint:
      glob: "terraform/*.tf"
      run: tflint --chdir=terraform
    gitleaks:
      run: gitleaks protect --staged
```

**Step 2: Commit**

```bash
git add lefthook.yml
git commit -m "chore: add lefthook pre-commit hooks for fmt, validate, lint, gitleaks"
```

---

### Task 5: Create terraform/versions.tf

**Files:**
- Create: `terraform/versions.tf`

**Step 1: Write provider requirements**

```hcl
terraform {
  required_version = "~> 1.14"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.96"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.3"
    }
  }
}
```

**Step 2: Commit**

```bash
git add terraform/versions.tf
git commit -m "feat: add required Terraform providers (proxmox, talos, sops)"
```

---

### Task 6: Create terraform/variables.tf

**Files:**
- Create: `terraform/variables.tf`

**Step 1: Write variable declarations**

Only `proxmox_api_token` is encrypted via SOPS. All other configuration is plaintext variables.

```hcl
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string
}

variable "proxmox_ssh_username" {
  description = "SSH username for the Proxmox host"
  type        = string
  default     = "terraform"
}

variable "proxmox_node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "talos_node_ip" {
  description = "IP address for the TalosOS node"
  type        = string
}

variable "gateway" {
  description = "Default gateway for the TalosOS node"
  type        = string
}

variable "vm_name" {
  description = "Name of the TalosOS VM"
  type        = string
  default     = "talos-cp-1"
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "cloudlab"
}

variable "talos_version" {
  description = "TalosOS version to deploy"
  type        = string
  default     = "v1.12.4"
}

variable "talos_schematic_id" {
  description = "Schematic ID from factory.talos.dev (includes qemu-guest-agent and nfs-utils extensions)"
  type        = string
}

variable "vm_mac_address" {
  description = "Fixed MAC address for the TalosOS VM (for DHCP reservation)"
  type        = string
  default     = "BC:24:11:CA:FE:01"
}

variable "vm_cpu_cores" {
  description = "Number of CPU cores for the VM"
  type        = number
  default     = 4
}

variable "vm_memory_mb" {
  description = "Memory in MiB for the VM"
  type        = number
  default     = 16384
}

variable "vm_disk_gb" {
  description = "Disk size in GiB for the VM"
  type        = number
  default     = 100
}
```

**Step 2: Commit**

```bash
git add terraform/variables.tf
git commit -m "feat: add Terraform variable declarations"
```

---

### Task 7: Create terraform/.tflint.hcl

**Files:**
- Create: `terraform/.tflint.hcl`

**Step 1: Write tflint config**

```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
```

**Step 2: Commit**

```bash
git add terraform/.tflint.hcl
git commit -m "chore: add tflint configuration with recommended preset"
```

---

### Task 8: Create terraform/main.tf

**Files:**
- Create: `terraform/main.tf`

**Step 1: Write SOPS data source, Proxmox provider, image download, and VM resource**

```hcl
# --- Secrets ---

provider "sops" {}

# Ephemeral: API token stays out of Terraform state
ephemeral "sops_file" "secrets" {
  source_file = "${path.module}/secrets.enc.json"
}

# --- Proxmox ---

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = ephemeral.sops_file.secrets.data["proxmox_api_token"]
  insecure  = true # Self-signed cert on homelab Proxmox

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}

# --- TalosOS Image ---

resource "proxmox_virtual_environment_download_file" "talos_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node_name
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64.iso"
  file_name    = "talos-${var.talos_version}-metal-amd64.iso"
}

# --- VM ---

resource "proxmox_virtual_environment_vm" "talos" {
  name      = var.vm_name
  node_name = var.proxmox_node_name

  bios    = "ovmf"
  machine = "q35"

  scsi_hardware   = "virtio-scsi-single"
  stop_on_destroy = true

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  efi_disk {
    datastore_id = "local-lvm"
  }

  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = var.vm_disk_gb
    iothread     = true
    discard      = "on"
  }

  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_image.id
    interface = "ide2"
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = var.vm_mac_address
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}
```

**Step 2: Commit**

```bash
git add terraform/main.tf
git commit -m "feat: add Proxmox provider, TalosOS image download, and VM resource"
```

---

### Task 9: Create terraform/talos.tf

**Files:**
- Create: `terraform/talos.tf`

**Step 1: Write Talos provider config, machine secrets, config generation, apply, bootstrap, and kubeconfig**

```hcl
provider "talos" {}

# --- VM IP (for initial connection before static IP is configured) ---

locals {
  # Find the first non-loopback IPv4 address reported by the QEMU guest agent.
  # The interface index varies by OS; flatten and filter to avoid hardcoding it.
  vm_ip = [
    for addr in flatten(proxmox_virtual_environment_vm.talos.ipv4_addresses) :
    addr if addr != "127.0.0.1"
  ][0]
}

# --- Machine Secrets ---

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# --- Machine Configuration ---

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.talos_node_ip}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

# --- Client Configuration ---

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.talos_node_ip]
  nodes                = [var.talos_node_ip]
}

# --- Apply Configuration ---

resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.vm_ip

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/sda"
          image = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}"
        }
        network = {
          interfaces = [{
            deviceSelector = {
              driver = "virtio_net"
            }
            addresses = ["${var.talos_node_ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.gateway
            }]
          }]
        }
      }
    }),
    yamlencode({
      machine = {
        kubelet = {
          extraArgs = {
            node-ip = var.talos_node_ip
          }
        }
      }
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = var.vm_name
    }),
  ]
}

# --- Bootstrap ---

resource "talos_machine_bootstrap" "this" {
  node                 = var.talos_node_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.controlplane]
}

# --- Kubeconfig ---

resource "talos_cluster_kubeconfig" "this" {
  node                 = var.talos_node_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_bootstrap.this]
}
```

**Step 2: Commit**

```bash
git add terraform/talos.tf
git commit -m "feat: add Talos machine config, bootstrap, and kubeconfig retrieval"
```

---

### Task 10: Create terraform/outputs.tf

**Files:**
- Create: `terraform/outputs.tf`

**Step 1: Write outputs for talosconfig, kubeconfig, and vm_id**

```hcl
output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.talos.vm_id
}

output "talosconfig" {
  description = "Talos client configuration"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubernetes kubeconfig"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}
```

**Step 2: Commit**

```bash
git add terraform/outputs.tf
git commit -m "feat: add Terraform outputs for vm_id, talosconfig, kubeconfig"
```

---

### Task 11: Create secrets.enc.json (manual)

This step requires the user's age public key and Proxmox credentials. The user must complete this manually.

**Step 1: Create and encrypt secrets**

The user creates the secrets file with the API token and encrypts it:

```bash
cat > terraform/secrets.enc.json <<'EOF'
{
  "proxmox_api_token": "user@pam!tokenid=secret-value"
}
EOF
sops encrypt -i terraform/secrets.enc.json
```

Non-secret configuration (endpoint, node name, IPs) goes in `terraform.tfvars`:

```bash
cat > terraform/terraform.tfvars <<'EOF'
proxmox_endpoint     = "https://<proxmox-ip>:8006"
proxmox_ssh_username = "terraform"
proxmox_node_name    = "pve"
talos_node_ip        = "192.168.1.100"
gateway              = "192.168.1.1"
talos_schematic_id   = "<id-from-factory.talos.dev>"
EOF
```

**Step 2: Commit encrypted secrets**

```bash
git add terraform/secrets.enc.json
git commit -m "feat: add SOPS-encrypted Proxmox credentials and network config"
```

---

### Task 12: Generate Talos schematic ID (manual)

This step requires the user to visit factory.talos.dev.

**Step 1: Generate schematic**

1. Go to [factory.talos.dev](https://factory.talos.dev)
2. Select TalosOS version `v1.12.4`
3. Enable Secure Boot
4. Add extensions: `siderolabs/qemu-guest-agent`, `siderolabs/nfs-utils`
5. Copy the schematic ID
6. Set `talos_schematic_id` in `terraform/terraform.tfvars`

---

### Task 13: Run setup and validate

**Step 1: Install tools**

Run: `mise install`
Expected: All tools installed at pinned versions.

**Step 2: Initialize tflint plugins**

Run: `cd terraform && tflint --init`
Expected: Terraform plugin downloaded.

**Step 3: Initialize Terraform**

Run: `mise run tf:init`
Expected: All three providers downloaded. Lock file created.

**Step 4: Run validation**

Run: `mise run tf:check`
Expected: All checks pass (fmt, validate, tflint).

**Step 5: Commit lock file**

```bash
git add terraform/.terraform.lock.hcl
git commit -m "chore: add Terraform provider lock file"
```

---

### Task 14: Install lefthook and verify hooks

**Step 1: Install lefthook hooks**

Run: `lefthook install`
Expected: Pre-commit hook installed in `.git/hooks/`.

**Step 2: Verify hooks work**

Make a no-op change to verify hooks fire:

Run: `lefthook run pre-commit`
Expected: All hooks pass (fmt-check, validate, lint, gitleaks).
