# Observability Stack — Design

## Goal

Monitor cluster health, debug deployments, and aggregate logs through a unified Grafana interface. Pushover delivers alerts to mobile when things break.

This design combines roadmap steps 8 (monitoring), 9 (log aggregation), and 10 (alerting) into one cohesive observability stack. It does not depend on step 7 (internal DNS).

## Approach

Four components, deployed in order:

1. **kube-prometheus-stack** — Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics in a single Helm chart. Batteries included.
2. **Loki** — Log aggregation with label-based indexing. Lightweight alternative to Elasticsearch.
3. **Alloy** — Grafana's OpenTelemetry-native log collector. Replaces Promtail with a future-proof pipeline architecture.
4. **Flux notification-controller** — Pushes GitOps events (reconciliation failures, source errors) to Alertmanager. Already installed; needs only a Provider and Alert resource.

### Why kube-prometheus-stack over individual charts

The chart bundles ~30 pre-built alert rules, dashboards for node health, pod resources, and API server metrics, and wires Prometheus to Grafana automatically. Installing each component separately produces the same result with more work and no additional learning value.

### Why Alloy over Promtail

Grafana is retiring Promtail in favor of Alloy, their OpenTelemetry-native collector. Alloy uses River configuration syntax (an HCL-like language) and supports metrics, logs, and traces through a single pipeline. Starting with Alloy avoids a future migration and opens the door to distributed tracing (Tempo) later.

### Why Loki single-binary mode

Loki supports three deployment modes: single-binary, simple-scalable, and microservices. Single-binary runs all components (ingester, querier, compactor) in one process. A single-node homelab cluster does not need horizontal scaling. Single-binary keeps resource usage low and simplifies debugging.

### Thanos sidecar — deferred

Thanos extends Prometheus with long-term object storage and multi-cluster query federation. Neither capability is needed on a single-node cluster with 7-day retention. If the cluster expands to multiple nodes or requires months of metric history, Thanos becomes the natural next step. Added to the roadmap as a future item.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                   monitoring namespace                │
│                                                       │
│  ┌─────────────────────────┐   ┌───────────────────┐  │
│  │  kube-prometheus-stack   │   │       Loki        │  │
│  │   ├─ Prometheus          │   │  (single-binary)  │  │
│  │   ├─ Grafana             │   └───────────────────┘  │
│  │   ├─ Alertmanager        │                          │
│  │   ├─ node-exporter       │   ┌───────────────────┐  │
│  │   └─ kube-state-metrics  │   │  Alloy (DaemonSet)│  │
│  └─────────────────────────┘   │  → ships to Loki   │  │
│                                 └───────────────────┘  │
└──────────────────────────────────────────────────────┘
          │                             │
          ▼                             ▼
    Alertmanager ──► Pushover     Grafana (unified)
                     (mobile)     metrics + logs
```

All components share the `monitoring` namespace. Grafana serves as the single interface — kube-prometheus-stack installs it, Loki registers as an additional datasource via sidecar auto-discovery. Alloy runs as a DaemonSet (one pod on this single-node cluster) collecting container logs and forwarding them to Loki.

Flux notification-controller (in `flux-system`) pushes GitOps events to Alertmanager through a Provider resource. This gives a second signal path for reconciliation failures alongside Prometheus scraping.

## Kubernetes Deployment

### File Structure

```
kubernetes/infrastructure/
├── kustomization.yaml              # add: monitoring, loki, alloy
├── monitoring/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── helmrepository.yaml         # prometheus-community charts
│   ├── helmrelease.yaml            # kube-prometheus-stack
│   ├── secret.enc.yaml             # Pushover + Grafana admin credentials
│   ├── httproute-grafana.yaml
│   ├── httproute-prometheus.yaml
│   └── httproute-alertmanager.yaml
├── loki/
│   ├── kustomization.yaml
│   ├── helmrepository.yaml         # grafana charts
│   ├── helmrelease.yaml            # loki (single-binary)
│   └── grafana-datasource.yaml     # ConfigMap for sidecar auto-discovery
└── alloy/
    ├── kustomization.yaml
    ├── helmrelease.yaml            # references grafana HelmRepository from loki/
    └── httproute-alloy.yaml
```

### Dependency Chain

Flux Kustomizations enforce deployment order through the existing `infrastructure.yaml` Kustomization. No new Flux CRDs needed — `dependsOn` within HelmReleases handles sequencing:

1. **monitoring** — installs Prometheus, Grafana, Alertmanager (no dependencies beyond existing infrastructure)
2. **loki** (depends on monitoring) — Grafana must exist for the datasource sidecar to register Loki
3. **alloy** (depends on loki) — needs Loki's push endpoint available

### Flux Notifications

A `Provider` (type: alertmanager) and `Alert` resource in `flux-system/` push reconciliation events to Alertmanager. These resources live alongside the existing Flux CRDs, not in the monitoring namespace.

## kube-prometheus-stack Configuration

### Enabled

- **Prometheus** — 7-day retention, 30s scrape interval, NFS-backed 10Gi PVC
- **Grafana** — NFS-backed 1Gi PVC, admin password from SOPS secret, sidecar watches for datasource ConfigMaps
- **Alertmanager** — Pushover receiver, NFS-backed 1Gi PVC for silence and notification state
- **node-exporter** — host metrics DaemonSet, default configuration
- **kube-state-metrics** — Kubernetes object metrics, default configuration
- **Default PrometheusRules** — all ~30 pre-built alert rules enabled
- **Default dashboards** — node health, pod resources, API server, all enabled

### Disabled

- **Thanos sidecar** — deferred to roadmap (see above)
- **Prometheus remote write** — no external metrics store

## Loki Configuration

- **Mode:** single-binary (one Deployment, one PVC)
- **Storage:** NFS-backed 10Gi PVC for chunks and index
- **Retention:** 7 days (`limits_config.retention_period: 168h`), compactor deletes expired chunks
- **Auth:** disabled (cluster-internal traffic only)
- **Grafana datasource:** a ConfigMap labeled `grafana_datasource: "1"` so kube-prometheus-stack's Grafana sidecar auto-discovers it

## Alloy Configuration

- **Mode:** DaemonSet (one pod on the single node)
- **Pipeline:** Kubernetes discovery → label enrichment (namespace, pod, container, node) → Loki push (`http://loki.monitoring.svc:3100/loki/api/v1/push`)
- **Config format:** River syntax, embedded in HelmRelease values. Extracted to a ConfigMap if complexity grows.
- **Noise reduction:** drops health-check logs from `kube-system` (configurable)

## Alert Rules

### Routing

```
Route tree:
├── Critical → Pushover priority 1 (bypasses quiet hours)
│   ├── KubePodCrashLooping
│   ├── NodeFilesystemSpaceFillingUp (>90%)
│   ├── NodeMemoryHighUtilization (>90%)
│   ├── KubeNodeNotReady
│   └── TargetDown
│
├── Warning → Pushover priority 0 (respects quiet hours)
│   ├── KubeDeploymentReplicasMismatch
│   ├── NodeFilesystemSpaceFillingUp (>80%)
│   ├── CertManagerCertExpirySoon (<7d)
│   ├── FluxReconciliationFailure
│   └── KubePersistentVolumeFillingUp
│
└── Null receiver (silenced)
    └── Watchdog
```

### Custom PrometheusRules

Two rules not included in the chart defaults:

- **FluxReconciliationFailure** — fires when `gotk_reconcile_condition{type="Ready",status="False"}` persists for 5 minutes. Catches broken Kustomizations, HelmReleases, and GitRepository syncs.
- **CertManagerCertExpirySoon** — fires when `certmanager_certificate_expiration_timestamp_seconds` is less than 7 days away. Safety net if automated renewal fails silently.

### SOPS Secret

One encrypted secret (`secret.enc.yaml`) in the monitoring namespace containing:

- `pushover_user_key` — Pushover user/group identifier
- `pushover_api_token` — Pushover application API token
- `grafana_admin_password` — Grafana admin password

## Exposed Services

Four HTTPRoutes, all using the existing wildcard certificate for `*.catinthehack.ca`:

| Service | Hostname | Authentication |
|---------|----------|----------------|
| Grafana | `grafana.catinthehack.ca` | Built-in login (admin + SOPS password) |
| Prometheus | `prometheus.catinthehack.ca` | None (private network only) |
| Alertmanager | `alertmanager.catinthehack.ca` | None (private network only) |
| Alloy | `alloy.catinthehack.ca` | None (private network only) |

Prometheus, Alertmanager, and Alloy have no built-in authentication. The cluster sits on a private network behind a home router, so this is acceptable for now. These services become the first candidates for the authentication gateway (step 12).

## Storage

### NFS PersistentVolumeClaims

| Component | Size | Purpose |
|-----------|------|---------|
| Prometheus | 10Gi | TSDB blocks (7 days of metrics) |
| Loki | 10Gi | Log chunks and index (7 days) |
| Grafana | 1Gi | Dashboard state, user preferences |
| Alertmanager | 1Gi | Silence state, notification log |
| **Total** | **22Gi** | All on Synology NFS |

All use the existing `nfs-client` default StorageClass.

### Resource Estimates

| Component | Memory Request | Memory Limit |
|-----------|---------------|-------------|
| Prometheus | 256Mi | 512Mi |
| Grafana | 128Mi | 256Mi |
| Alertmanager | 32Mi | 64Mi |
| node-exporter | 32Mi | 64Mi |
| kube-state-metrics | 32Mi | 64Mi |
| Loki | 256Mi | 512Mi |
| Alloy | 128Mi | 256Mi |
| **Total** | **~864Mi** | **~1.7Gi** |

Under 2Gi limit on a 32GB machine — plenty of headroom.

## Implementation Order

Four sequential stages within a single branch:

1. **kube-prometheus-stack** — namespace, HelmRepository, HelmRelease, SOPS secret, HTTPRoutes, custom PrometheusRules. Verify: Grafana loads, Prometheus targets healthy, Alertmanager routes configured.
2. **Loki** — HelmRepository, HelmRelease, Grafana datasource ConfigMap. Verify: Loki appears as datasource in Grafana.
3. **Alloy** — HelmRelease, HTTPRoute, River pipeline config. Verify: pipeline healthy in Alloy UI, logs visible in Grafana Explore.
4. **Flux notifications** — Provider and Alert in `flux-system/`. Verify: trigger deliberate Flux failure, confirm alert in Alertmanager.

## Out of Scope

- Authentication for exposed UIs (step 12)
- Thanos sidecar (added to roadmap)
- Distributed tracing / Tempo
- Custom Grafana dashboards beyond chart defaults
- Alloy metrics collection via OTel pipeline

## Prerequisites

1. **Pushover account** — create an application to obtain the API token and user key
2. **SOPS encryption** — encrypt Pushover credentials and Grafana admin password as `secret.enc.yaml`
3. **`/etc/hosts` entries** — add `grafana`, `prometheus`, `alertmanager`, and `alloy` subdomains pointing to `192.168.20.100`

## Roadmap Updates

- **Steps 8, 9, 10** — combined into one observability stack (this design)
- **Thanos sidecar (new)** — add to Phase 4 as long-term metrics storage and multi-cluster query federation
- **Promtail** — replaced by Alloy in step 9 description

## Validation

1. **Flux reconciliation** — all new HelmReleases reconcile without errors. `mise run check` passes.
2. **Prometheus targets** — `prometheus.catinthehack.ca/targets` shows all targets as UP.
3. **Grafana dashboards** — default dashboards load with data at `grafana.catinthehack.ca`.
4. **Loki integration** — Grafana Explore with Loki datasource returns container logs.
5. **Alloy pipeline** — `alloy.catinthehack.ca` shows healthy pipeline components.
6. **Pushover alert** — trigger a test alert; confirm mobile notification arrives.
7. **Flux notification** — break a Kustomization deliberately; confirm alert fires through both Prometheus scrape and Flux notification-controller.
