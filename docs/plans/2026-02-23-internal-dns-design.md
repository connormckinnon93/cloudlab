# Internal DNS Design

## Goal

Resolve `*.catinthehack.ca` to `192.168.20.100` on the home network, replacing manual `/etc/hosts` entries. Devices discover the DNS server automatically through DHCP.

## Architecture

Two components share the `adguard` namespace in the Kubernetes cluster:

```
[Home Network Devices]
        |
        v  (UDP/TCP 53 via hostNetwork)
  AdGuard Home
        |
        +--[*.catinthehack.ca]---> 192.168.20.100 (DNS rewrite, instant)
        |
        +--[everything else]-----> Unbound (recursive resolution)
                                      |
                                      v
                                 Root nameservers
```

**AdGuard Home** binds to port 53 on the node IP via `hostNetwork: true`. A DNS rewrite rule maps `*.catinthehack.ca → 192.168.20.100`. AdGuard also blocks ads and trackers for the entire network. The existing Traefik gateway exposes its web UI at `adguard.catinthehack.ca`.

**Unbound** resolves all other queries recursively, querying root nameservers directly instead of forwarding to a third-party provider. AdGuard Home uses Unbound as its sole upstream. Unbound runs as a ClusterIP service, accessible only within the cluster.

## Directory Structure

```
kubernetes/infrastructure/
├── adguard/
│   ├── kustomization.yaml          # namespace + sub-components
│   ├── namespace.yaml
│   ├── adguard-home/
│   │   ├── kustomization.yaml
│   │   ├── helmrelease.yaml
│   │   ├── helmrepository.yaml
│   │   ├── httproute.yaml          # adguard.catinthehack.ca
│   │   └── secret.enc.yaml         # SOPS-encrypted admin password
│   └── unbound/
│       ├── kustomization.yaml
│       ├── helmrelease.yaml
│       └── helmrepository.yaml
└── kustomization.yaml              # add ./adguard entry
```

## AdGuard Home

### Network

| Port | Protocol | Exposure | Purpose |
|------|----------|----------|---------|
| 53 | UDP+TCP | hostNetwork | DNS server |
| 3000 | TCP | HTTPRoute | Web UI |

The `adguard` namespace requires `pod-security.kubernetes.io/enforce: privileged` because TalosOS's baseline PSA forbids hostNetwork without elevated privileges.

### Configuration

The gabe565 Helm chart generates `AdGuardHome.yaml` from the `config` values key in the HelmRelease. The chart copies the generated config to the config PVC on first boot only; subsequent restarts preserve UI changes. Key settings seeded via HelmRelease values:

- Upstream DNS: `unbound.adguard.svc.cluster.local`
- DNS rewrite: `*.catinthehack.ca → 192.168.20.100`
- Default blocklists (AdGuard DNS filter)

The admin password (bcrypt hash) lives in a SOPS-encrypted Secret (`secret.enc.yaml`). Flux injects it via `valuesFrom`, deep-merging the password into `config.users` before Helm renders the config.

Delete the `conf` PVC and restart the pod to reset to the Git config. Copy the running config and update the HelmRelease values to capture UI changes back to Git.

### Persistence

| Mount Path | PVC Size | Purpose |
|------------|----------|---------|
| `/opt/adguardhome/conf` | 1Gi | Config, DNS rewrites, filters |
| `/opt/adguardhome/work` | 2Gi | Query logs, stats |

Both PVCs use the existing `nfs` StorageClass backed by the Synology NAS.

## Unbound

Unbound needs minimal configuration:

- Recursive mode (no forwarders) — queries root nameservers directly
- DNSSEC validation enabled
- Access restricted to cluster CIDR
- ClusterIP service on port 53

Unbound caches in memory, rebuilds on restart, and ships root hints in the container image. No persistence required.

A ConfigMap mounted into the pod holds the configuration.

## Deployment Order

1. **Namespace** — `adguard` with privileged PSA label
2. **Unbound** — Starts first as AdGuard Home's upstream
3. **AdGuard Home** — Starts and connects to Unbound

AdGuard Home retries upstream connections until Unbound is ready, so no explicit Flux dependency is needed. Both deploy under the existing `infrastructure` Flux Kustomization. No new CRDs are involved, so no manual bootstrap step is required.

## Post-Deployment Steps

1. **TalosOS static nameservers:** Verify `machine.network.nameservers` is set in the Talos machine config (e.g., `["1.1.1.1", "8.8.8.8"]`). Without static nameservers, the node acquires DNS from DHCP. After the router points DHCP DNS at `192.168.20.100`, a node restart deadlocks: the node cannot resolve DNS to pull images, so the cluster and AdGuard cannot start. This is a Terraform change, not a Kubernetes manifest change.
2. **Router DHCP:** Set primary DNS to `192.168.20.100`, secondary to `1.1.1.1` (fallback if cluster is down)
3. **Verify DNS:** `dig whoami.catinthehack.ca @192.168.20.100` returns `192.168.20.100`
4. **Verify Web UI:** Visit `adguard.catinthehack.ca` and log in

## Trade-offs

**Cluster dependency:** A cluster outage breaks network DNS. The secondary DNS (`1.1.1.1`) in DHCP provides a fallback, but devices may cache the primary and delay failover. Acceptable for a single-operator homelab.

**Config drift:** AdGuard Home UI changes do not propagate to Git. The operator must manually capture them in the HelmRelease values. This trade-off is deliberate: full GitOps would overwrite config on every restart, resetting filter timestamps and forcing re-downloads.
