# Cloudlab

Terraform configuration that provisions a single-node Kubernetes cluster on Proxmox using TalosOS.

## Prerequisites

- [Mise](https://mise.jdx.dev) installed
- A Proxmox node with API token configured
- An age keypair for SOPS encryption

## Setup

Install tools and configure git hooks:

```bash
mise run setup
```

Generate an age keypair (if you don't have one):

```bash
age-keygen -o .age-key.txt
```

Copy the public key from the output and add it to `.sops.yaml`.

Create the secrets file:

```bash
cat > terraform/secrets.enc.json <<'EOF'
{
  "proxmox_api_token": "user@pam!tokenid=secret-value"
}
EOF
sops encrypt -i terraform/secrets.enc.json
```

Generate a TalosOS schematic ID at [factory.talos.dev](https://factory.talos.dev) with these extensions:

- `siderolabs/qemu-guest-agent`
- `siderolabs/nfs-mount`

## Usage

```bash
mise run tf init                     # Initialize Terraform
mise run tf plan                     # Preview changes
mise run tf apply                    # Provision and bootstrap
mise run config:export               # Encrypt outputs
mise run config:decrypt              # Decrypt configs for local use
mise run flux:sops-key               # Load age key for SOPS decryption
kubectl get nodes                    # Verify
```

## Architecture

A single TalosOS VM runs on Proxmox as both the Kubernetes control plane and worker node. Terraform handles the full lifecycle:

1. Downloads the TalosOS image to Proxmox
2. Creates the VM with the image
3. Generates and applies TalosOS machine configuration
4. Bootstraps the single-node Kubernetes cluster
5. Retrieves and encrypts the kubeconfig and talosconfig

Secrets are encrypted with SOPS (age backend) and stored in git. The SOPS Terraform provider decrypts them inline during plan/apply — no manual decrypt step required.

## Operations

**Re-bootstrap Flux after cluster rebuild:** `flux bootstrap github` is idempotent. If the cluster is reprovisioned (`mise run tf apply`), re-run the bootstrap command to reinstall Flux controllers. The existing deploy key and repo configuration are reused.

**Rotate the Flux deploy key:** The SSH deploy key registered during bootstrap has no expiry. To rotate it, delete the existing deploy key in GitHub repo settings, then re-run `flux bootstrap github` with a new fine-grained PAT.

## Tools

| Tool | Purpose |
|------|---------|
| Terraform | Infrastructure provisioning |
| talosctl | TalosOS management |
| SOPS + age | Secrets encryption |
| kubectl | Kubernetes access |
| tflint | Terraform linting |
| lefthook | Git pre-commit hooks |
| Mise | Tool version management and task runner |

## Roadmap

Thirty-one steps in six phases. Each step is self-contained; dependency order is respected within phases.

### Decisions to Make First

These choices are difficult to reverse once workloads depend on them. Decide before starting the relevant step.

| Decision | Step | Options |
|----------|------|---------|
| ~~Flux repo structure~~ | ~~2~~ | ~~Monorepo~~ (chosen) ~~vs separate GitOps repo~~ |
| ~~NFS provisioner~~ | ~~4~~ | ~~nfs-subdir-external-provisioner~~ (chosen) ~~vs democratic-csi~~ |
| ~~Ingress approach~~ | ~~5~~ | ~~Traefik + Gateway API~~ (chosen) |
| Service domain | 7 | `*.home.arpa`, `*.cloudlab.local`, or a real domain with split-horizon DNS |
| Auth architecture | 12 | Authelia (lightweight forward-auth) vs Authentik (full OIDC identity provider) |
| VCS platform | 13 | Gitea vs Forgejo |
| Secrets manager | 15 | Infisical self-hosted vs other |

### Phase 1: Foundation

1. ~~**SecureBoot + disk encryption** — EFI SecureBoot, virtual TPM, LUKS2 on STATE and EPHEMERAL partitions~~
2. ~~**Bootstrap Flux** — GitHub repo, CI, GitOps foundation~~
3. ~~**SOPS + Flux** — Decrypt SOPS-encrypted secrets in-cluster via Flux's kustomize-controller~~
4. ~~**NFS storage provisioner** — Dynamic PersistentVolumes backed by Synology NAS~~
5. ~~**Ingress controller** — Route external HTTP/HTTPS traffic to cluster services~~
6. ~~**cert-manager** — Automated TLS certificates via Let's Encrypt~~
7. **Internal DNS** — Resolve friendly service names to the ingress IP
8. **Monitoring** — Prometheus + Grafana for metrics, dashboards, and cluster health

### Phase 2: Operational Excellence

9. **Log aggregation** — Loki + Promtail for centralized container logs alongside Prometheus metrics
10. **Alerting** — Alertmanager with notifications to Pushover, Discord, or similar
11. ~~**Kyverno** — Image signature verification first, general policies later~~
12. **Authentication gateway** — Single sign-on and 2FA in front of all services
13. **Gitea/Forgejo** — First self-hosted app; migrate Flux source from GitHub
14. **Renovate** — Automated dependency updates (against Gitea)
15. **Infisical** — Self-hosted secrets management; begin migrating from SOPS

### Phase 3: Expand and Harden

16. **Remote access** — Tailscale for secure access from outside the home network
17. **Network policies** — Cilium policies to isolate namespaces and restrict traffic
18. **Kyverno enforce mode** — Migrate image verification from audit to enforce
19. **Kyverno general policies** — Disallow privileged containers, require resource limits, disallow `latest` tag
20. **Multi-node expansion** — Add worker node(s); refactor Terraform with `for_each`
21. **Automated cluster upgrades** — Formalize TalosOS and Kubernetes upgrade workflow
22. **Remote Terraform state** — S3-compatible backend on Synology for state locking

### Phase 4: Advanced Platform

23. **Hubble observability** — Cilium's service map and flow visibility via eBPF
24. **PersistentVolume backups** — Volsync for scheduled PVC replication to NAS
25. **Cluster-wide backups** — Velero for scheduled backup and restore of all cluster resources
26. **Cluster dashboard** — Headlamp for visual cluster inspection behind auth

### Phase 5: Platform Maturity

27. **Image pull-through cache** — Spegel for peer-to-peer registry mirroring on-cluster
28. **Descheduler** — Evict pods that violate scheduling constraints over time

### Phase 6: Operational Confidence

29. **Chaos testing** — Break things on purpose; verify alerts fire and recovery works
30. **Resource quotas** — Per-namespace CPU/memory limits to prevent resource starvation
31. **GitOps repo refactor** — Kustomize base/overlays structure for multi-cluster readiness
