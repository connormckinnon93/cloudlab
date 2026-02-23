# Internal DNS Design

## Goal

Resolve `*.catinthehack.ca` to `192.168.20.100` on the home network, replacing manual `/etc/hosts` entries. Devices discover the DNS server automatically through DHCP.

## Architecture

Two components share the `adguard` namespace in the Kubernetes cluster:

```
[Home Network Devices]
        |
        v  (UDP/TCP 53 via hostPort)
  AdGuard Home
        |
        +--[*.catinthehack.ca]---> 192.168.20.100 (DNS rewrite, instant)
        |
        +--[everything else]-----> Unbound (recursive resolution)
                                      |
                                      v
                                 Root nameservers
```

**AdGuard Home** binds to port 53 on the node IP via hostPort. A DNS rewrite rule maps `*.catinthehack.ca → 192.168.20.100`. AdGuard also blocks ads and trackers for the entire network. The existing Traefik gateway exposes its web UI at `adguard.catinthehack.ca`.

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
│   │   ├── configmap.yaml          # AdGuardHome.yaml seed config
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
| 53 | UDP+TCP | hostPort | DNS server |
| 3000 | TCP | hostPort (initial setup), then HTTPRoute | Web UI |

The `adguard` namespace requires `pod-security.kubernetes.io/enforce: privileged` because TalosOS's baseline PSA forbids hostPort binding without elevated privileges.

### Configuration

A ConfigMap holds the full `AdGuardHome.yaml` with:

- Upstream DNS: `unbound.adguard.svc.cluster.local:53`
- DNS rewrite: `*.catinthehack.ca → 192.168.20.100`
- Default blocklists (AdGuard DNS filter)
- Bind addresses and port settings

An init container seeds the config on first boot only:

```bash
if [ ! -f /opt/adguardhome/conf/AdGuardHome.yaml ]; then
  cp /tmp/AdGuardHome.yaml /opt/adguardhome/conf/AdGuardHome.yaml
fi
```

The admin password (bcrypt hash) lives in a SOPS-encrypted Secret (`secret.enc.yaml`), injected separately from the ConfigMap, following the same pattern as cert-manager's DigitalOcean API token.

Delete the `conf` PVC and restart the pod to reset to the Git config. Copy the running config and update the ConfigMap to capture UI changes back to Git.

### Persistence

| Mount Path | PVC Size | Purpose |
|------------|----------|---------|
| `/opt/adguardhome/conf` | 1Gi | Config, DNS rewrites, filters |
| `/opt/adguardhome/work` | 2Gi | Query logs, stats |

Both PVCs use the existing `nfs-client` StorageClass backed by the Synology NAS.

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

1. **Router DHCP:** Set primary DNS to `192.168.20.100`, secondary to `1.1.1.1` (fallback if cluster is down)
2. **Verify DNS:** `dig whoami.catinthehack.ca @192.168.20.100` returns `192.168.20.100`
3. **Verify Web UI:** Visit `adguard.catinthehack.ca` and log in

## Trade-offs

**Cluster dependency:** A cluster outage breaks network DNS. The secondary DNS (`1.1.1.1`) in DHCP provides a fallback, but devices may cache the primary and delay failover. Acceptable for a single-operator homelab.

**Config drift:** AdGuard Home UI changes do not propagate to Git. The operator must manually capture them in the ConfigMap. This trade-off is deliberate: full GitOps would overwrite config on every restart, resetting filter timestamps and forcing re-downloads.
