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

Thirty steps in six phases. Each step is self-contained; dependency order is respected within phases.

### Decisions to Make First

These choices are difficult to reverse once workloads depend on them. Decide before starting the relevant step.

| Decision | Step | Options |
|----------|------|---------|
| ~~Flux repo structure~~ | ~~2~~ | ~~Monorepo~~ (chosen) ~~vs separate GitOps repo~~ |
| NFS provisioner | 4 | democratic-csi (creates NFS shares on Synology) vs nfs-subdir-external-provisioner (subdirectories on one export) |
| Ingress approach | 5 | ingress-nginx, Cilium ingress, or Gateway API directly |
| Service domain | 7 | `*.home.arpa`, `*.cloudlab.local`, or a real domain with split-horizon DNS |
| Auth architecture | 13 | Authelia (lightweight forward-auth) vs Authentik (full OIDC identity provider) |
| VCS platform | 14 | Gitea vs Forgejo |
| Secrets manager | 16 | Infisical self-hosted vs other |

### Phase 1: Foundation

1. ~~**SecureBoot + disk encryption** — EFI SecureBoot, virtual TPM, LUKS2 on STATE and EPHEMERAL partitions~~
2. **Bootstrap Flux** — GitHub repo, CI, GitOps foundation
3. **SOPS + Flux** — Decrypt SOPS-encrypted secrets in-cluster via Flux's kustomize-controller
4. **NFS storage provisioner** — Dynamic PersistentVolumes backed by Synology NAS
5. **Ingress controller** — Route external HTTP/HTTPS traffic to cluster services
6. **cert-manager** — Automated TLS certificates via Let's Encrypt
7. **Internal DNS** — Resolve friendly service names to the ingress IP
8. **Monitoring** — Prometheus + Grafana for metrics, dashboards, and cluster health

### Phase 2: Operational Excellence

9. **Log aggregation** — Loki + Promtail for centralized container logs alongside Prometheus metrics
10. **Alerting** — Alertmanager with notifications to Pushover, Discord, or similar
11. **Kyverno** — Image signature verification first, general policies later
12. **etcd backups** — Periodic `talosctl etcd snapshot` to Synology NAS (Proxmox VM backups cover the gap until here)
13. **Authentication gateway** — Single sign-on and 2FA in front of all services
14. **Gitea/Forgejo** — First self-hosted app; migrate Flux source from GitHub
15. **Renovate** — Automated dependency updates (against Gitea)
16. **Infisical** — Self-hosted secrets management; begin migrating from SOPS

### Phase 3: Expand and Harden

17. **Remote access** — Tailscale for secure access from outside the home network
18. **Network policies** — Cilium policies to isolate namespaces and restrict traffic
19. **Multi-node expansion** — Add worker node(s); refactor Terraform with `for_each`
20. **Automated cluster upgrades** — Formalize TalosOS and Kubernetes upgrade workflow
21. **Remote Terraform state** — S3-compatible backend on Synology for state locking

### Phase 4: Advanced Platform

22. **Hubble observability** — Cilium's service map and flow visibility via eBPF
23. **PersistentVolume backups** — Volsync for scheduled PVC replication to NAS
24. **Cluster dashboard** — Headlamp for visual cluster inspection behind auth

### Phase 5: Platform Maturity

25. **Gateway API migration** — Move from Ingress resources to HTTPRoute/Gateway
26. **Image pull-through cache** — Spegel for peer-to-peer registry mirroring on-cluster
27. **Descheduler** — Evict pods that violate scheduling constraints over time

### Phase 6: Operational Confidence

28. **Chaos testing** — Break things on purpose; verify alerts fire and recovery works
29. **Resource quotas** — Per-namespace CPU/memory limits to prevent resource starvation
30. **GitOps repo refactor** — Kustomize base/overlays structure for multi-cluster readiness
