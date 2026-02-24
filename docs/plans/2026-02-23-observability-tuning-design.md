# Observability Tuning and Headlamp Dashboard

## Purpose

The monitoring stack (Prometheus, Grafana, Alertmanager, Loki, Alloy) collects metrics and logs but lacks actionable alerting, custom dashboards, and readable notifications. Headlamp provides a Kubernetes object browser for quick triage. This design adds all four.

## Current State

**Alert rules:** Two custom rules exist — `FluxReconciliationFailure` (Flux resource not-ready for 5 minutes) and `CertManagerCertExpirySoon` (certificate expiring within 7 days). No rules cover node health, pod failures, or storage pressure.

**Notifications:** Pushover receives alerts at two priority levels (critical and warning). The notification template is broken — messages render raw Go template syntax instead of formatted text.

**Dashboards:** Only the default kube-prometheus-stack dashboards exist. No cluster health overview or log exploration dashboard.

**Kubernetes visibility:** No web UI for browsing Kubernetes objects. Triage requires `kubectl` in a terminal.

## Design

### 1. Fix Pushover Notification Template

The kube-prometheus-stack HelmRelease gains a `templateFiles` block under `alertmanager.templateFiles`. This block defines a custom Pushover notification template that controls the title, body, and HTML formatting for all Pushover receivers.

The template produces:

- **Title:** `[SEVERITY] AlertName` (e.g., `[critical] NodeNotReady`)
- **Body:** The alert's `summary` annotation. Falls back to `description` if `summary` is absent, then to `message`. Appends namespace and pod labels when present.
- **HTML:** Enabled. Bold severity, line breaks between fields.

Both `pushover-critical` and `pushover-warning` receivers reference this template. The null receiver for Watchdog stays unchanged.

### 2. Essential Alert Rules

Six new rules join the two existing ones. Each rule targets a failure mode that produces no visible symptom until something breaks.

#### Group: node-rules

**NodeNotReady**
- Expression: `kube_node_status_condition{condition="Ready",status="true"} == 0`
- Duration: 2 minutes
- Severity: critical
- Rationale: Single-node cluster. Node down means total outage.

**NodeFilesystemSpaceCritical**
- Expression: Filesystem usage exceeds 90% on root or NFS mounts
- Duration: 5 minutes
- Severity: critical
- Rationale: NFS backs Prometheus (10Gi), Loki (10Gi), Grafana (1Gi), PostgreSQL, and Alertmanager (1Gi). Running out of space corrupts all persistent workloads.

**NodeMemoryPressure**
- Expression: Available memory falls below 10% of total
- Duration: 5 minutes
- Severity: warning
- Rationale: OOMKiller evicts pods silently. Early warning prevents surprise restarts.

#### Group: workload-rules

**PodCrashLooping**
- Expression: Container restart count increases by more than 3 within 10 minutes
- Duration: 5 minutes
- Severity: warning
- Rationale: Catches restart loops before resource exhaustion.

**PodNotReady**
- Expression: Pod in non-ready state
- Duration: 10 minutes
- Severity: warning
- Rationale: The 10-minute threshold ignores rolling updates but catches stuck pods.

**PVCNearlyFull**
- Expression: PVC usage exceeds 85%
- Duration: 5 minutes
- Severity: warning
- Rationale: Early warning before a volume fills and crashes the application.

#### Existing rules (unchanged)

- **FluxReconciliationFailure** — warning, 5 minutes
- **CertManagerCertExpirySoon** — warning, 1 hour

#### What stays out

- **CPU pressure alerts** — single-node CPU spikes during reconciliation are normal. More noise than signal.
- **Log-based alerts from Loki** — requires the Loki ruler component, adding complexity for marginal value.
- **Chart default rules** — kube-prometheus-stack ships 100+ built-in rules, many of which fire on single-node clusters for benign reasons. The curated set above replaces them.

### 3. Cluster Health Dashboard

A single Grafana dashboard for at-a-glance cluster health. Provisioned as a JSON ConfigMap with the `grafana_dashboard: "1"` label. Grafana's sidecar auto-discovers it.

Four rows:

**Row 1 — Node vitals (stat panels)**

Four panels: CPU usage %, memory usage %, root disk usage %, NFS disk usage %. Color thresholds match alert thresholds — green below 70%, yellow below 90%, red at 90% and above. The dashboard turns red before the phone buzzes.

**Row 2 — Workload status (stat panels + table)**

Three stat panels: pods running vs total, pods not ready (count), crash-looping pods (count). One table: pods with restarts in the last hour, sorted by restart count. All zeros means everything is healthy.

**Row 3 — PVC usage (bar gauge)**

One bar per PVC showing percentage used. Labels include PVC name and namespace. Covers Prometheus, Loki, Grafana, PostgreSQL, and Alertmanager storage.

**Row 4 — Flux sync status (table)**

All Kustomizations and HelmReleases with their Ready condition and last reconciliation timestamp. Uses Flux controller metrics from the existing PodMonitor. One glance shows whether GitOps is in sync.

### 4. Log Explorer Dashboard

A Loki dashboard for investigating alerts. Provisioned identically to the cluster health dashboard — JSON ConfigMap with the sidecar label.

**Template variables (dropdowns across the top):**

- Namespace — populated from Loki label values
- Pod — filtered by selected namespace
- Search — free-text filter applied to log lines

**Panels:**

- **Log volume histogram** — bar chart of log lines per minute, colored by detected level (error = red, warn = yellow, info = blue)
- **Log stream** — raw log lines filtered by selected namespace, pod, and search text

The workflow: an alert fires about a crash-looping pod. Open this dashboard, select the namespace and pod from dropdowns, and see the logs around the crash. No manual LogQL required.

### 5. Headlamp Kubernetes Dashboard

Headlamp provides a web UI for browsing Kubernetes objects — pods, deployments, events, configmaps, CRD instances. It complements Grafana: Grafana shows what happened over time; Headlamp shows what a resource looks like right now.

**Deployment:**

- Namespace: `headlamp`
- HelmRelease from the `headlamp/headlamp` chart
- ServiceAccount with the built-in `view` ClusterRole (read-only across all namespaces)
- No plugins — start bare

**Access:**

- HTTPRoute: `headlamp.catinthehack.ca` attached to the Traefik gateway
- Authentik forward-auth covers it via the Kyverno policy — no additional auth configuration needed
- No in-app token auth — Authentik gates access; Headlamp trusts the ServiceAccount

**Flux hierarchy placement:** `kubernetes/apps/headlamp/`, alongside whoami. Headlamp is an end-user tool, not infrastructure that other components depend on.

## File Changes

| File | Action | Step |
|------|--------|------|
| `kubernetes/infrastructure/monitoring/helmrelease-kube-prometheus-stack.yaml` | Edit — add `templateFiles`, update receivers, add 6 alert rules | 1, 2 |
| `kubernetes/infrastructure/monitoring/grafana-dashboard-cluster-health.yaml` | Create — JSON ConfigMap | 3 |
| `kubernetes/infrastructure/monitoring/grafana-dashboard-log-explorer.yaml` | Create — JSON ConfigMap | 4 |
| `kubernetes/infrastructure/monitoring/kustomization.yaml` | Edit — add dashboard ConfigMaps to resource list | 3, 4 |
| `kubernetes/apps/headlamp/namespace.yaml` | Create | 5 |
| `kubernetes/apps/headlamp/helmrepository.yaml` | Create | 5 |
| `kubernetes/apps/headlamp/helmrelease.yaml` | Create — includes ServiceAccount, ClusterRoleBinding | 5 |
| `kubernetes/apps/headlamp/kustomization.yaml` | Create | 5 |
| `kubernetes/apps/kustomization.yaml` | Edit — add `headlamp` to resource list | 5 |
| `kubernetes/infrastructure-config/headlamp-httproute.yaml` | Create | 5 |
| `kubernetes/infrastructure-config/kustomization.yaml` | Edit — add HTTPRoute to resource list | 5 |

## Implementation Order

1. **Fix Pushover template** — validates the notification channel before adding rules
2. **Add alert rules** — new alerts produce readable notifications immediately
3. **Cluster health dashboard** — visual overview built on the same metrics the alerts query
4. **Log explorer dashboard** — investigation tool for when alerts fire
5. **Deploy Headlamp** — independent of monitoring; can run in parallel with steps 3-4

## Out of Scope

- Thanos sidecar (Phase 4, step 27) — extends Prometheus with long-term storage. Nothing here conflicts with future Thanos adoption.
- Hubble (Phase 4, step 23) — separate network observability data plane. No overlap with these dashboards.
- Log-based alerting from Loki — revisit if the curated Prometheus rules prove insufficient.
- Headlamp plugins — add after evaluating the base UI.
- CPU pressure alerts — too noisy on a single-node cluster.
- Chart default alert rules — replaced by the curated set above.

## Validation

- `mise run check` passes with all new and modified files
- Kustomize builds cleanly for `monitoring/`, `apps/`, and `infrastructure-config/`
- Kubeconform validates all new resources
- After deployment: send a test alert via Alertmanager API, confirm Pushover renders correctly
- After deployment: verify Grafana auto-discovers both dashboards and Loki datasource queries return data
- After deployment: access `headlamp.catinthehack.ca`, confirm Authentik login prompt, verify read-only cluster browsing
