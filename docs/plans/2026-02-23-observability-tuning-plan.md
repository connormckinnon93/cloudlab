# Observability Tuning Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix broken Pushover notifications, add essential alert rules, create two Grafana dashboards, and deploy Headlamp for cluster browsing.

**Architecture:** All monitoring changes modify the existing kube-prometheus-stack HelmRelease. Dashboards are ConfigMaps auto-discovered by Grafana's sidecar. Headlamp deploys as a standalone app in `kubernetes/apps/headlamp/` with read-only RBAC.

**Tech Stack:** kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki, Headlamp 0.40.0, Flux HelmRelease, Gateway API HTTPRoute

**Worktree:** `/Users/cm/Projects/cloudlab/.worktrees/observability-tuning` (branch: `feature/observability-tuning`)

---

## Prerequisites

None. All credentials (Pushover, Grafana admin) already exist in `secret.enc.yaml`. The monitoring stack is deployed and running.

---

## Task 1: Fix Pushover Notification Template

The current Pushover `title` and `message` fields use `{{ "{{" }}` escaping, which produces double-evaluated templates. Alertmanager renders the escaping into literal `{{ .CommonLabels.alertname }}` text instead of resolving the variable. The fix: remove the escaping and use direct Go template syntax. HelmRelease values are data — Flux and Helm pass them through without template processing.

**Files:**
- Modify: `kubernetes/infrastructure/monitoring/helmrelease-kube-prometheus-stack.yaml`

**Step 1: Update the Alertmanager receiver configs**

Replace the `receivers` block (lines 124-139) in the HelmRelease. Change:
- Remove `{{ "{{" }}` and `{{ "}}" }}` escaping from `title` and `message`
- Use direct Go template syntax: `{{ .CommonLabels.alertname }}`
- Add `html: "1"` to enable Pushover HTML formatting
- Improve message format: include severity, summary, namespace, and pod

The full `alertmanager` section (replace lines 87-139) becomes:

```yaml
    alertmanager:
      alertmanagerSpec:
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 64Mi
        storage:
          volumeClaimTemplate:
            spec:
              storageClassName: nfs
              accessModes:
                - ReadWriteOnce
              resources:
                requests:
                  storage: 1Gi
        secrets:
          - monitoring-secrets
      templateFiles:
        pushover.tmpl: |-
          {{ define "pushover.title" }}[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}{{ end }}
          {{ define "pushover.message" }}{{ range .Alerts }}{{ .Annotations.summary }}{{ if .Annotations.description }}
          {{ .Annotations.description }}{{ end }}{{ if .Labels.namespace }}
          Namespace: {{ .Labels.namespace }}{{ end }}{{ if .Labels.pod }}
          Pod: {{ .Labels.pod }}{{ end }}
          {{ end }}{{ end }}
      config:
        route:
          receiver: pushover-warning
          group_by:
            - alertname
            - namespace
          routes:
            - receiver: "null"
              matchers:
                - alertname = Watchdog
            - receiver: pushover-critical
              matchers:
                - severity = critical
              continue: false
            - receiver: pushover-warning
              matchers:
                - severity = warning
              continue: false
        receivers:
          - name: "null"
          - name: pushover-critical
            pushover_configs:
              - user_key_file: /etc/alertmanager/secrets/monitoring-secrets/pushover-user-key
                token_file: /etc/alertmanager/secrets/monitoring-secrets/pushover-api-token
                priority: "1"
                title: '{{ template "pushover.title" . }}'
                message: '{{ template "pushover.message" . }}'
          - name: pushover-warning
            pushover_configs:
              - user_key_file: /etc/alertmanager/secrets/monitoring-secrets/pushover-user-key
                token_file: /etc/alertmanager/secrets/monitoring-secrets/pushover-api-token
                priority: "0"
                title: '{{ template "pushover.title" . }}'
                message: '{{ template "pushover.message" . }}'
```

**Step 2: Validate**

Run: `mise run check`
Expected: All checks pass. Kustomize builds monitoring directory, kubeconform validates the HelmRelease.

**Step 3: Commit**

```bash
git add kubernetes/infrastructure/monitoring/helmrelease-kube-prometheus-stack.yaml
git commit -m "fix(monitoring): fix broken Pushover notification template

Remove double-escaped Go template syntax that rendered as raw template
text. Use templateFiles with named templates for clean Pushover output."
```

---

## Task 2: Add Essential Alert Rules

Six new rules in two groups. Each rule catches a failure mode invisible without active monitoring.

**Files:**
- Modify: `kubernetes/infrastructure/monitoring/helmrelease-kube-prometheus-stack.yaml`

**Step 1: Add node-rules and workload-rules groups**

Add two new entries under `additionalPrometheusRulesMap` (after the existing `cert-manager-rules` block, which ends around line 85). The existing `flux-rules` and `cert-manager-rules` stay unchanged.

Add this YAML at the same indentation level as `flux-rules` and `cert-manager-rules`:

```yaml
      node-rules:
        groups:
          - name: node.rules
            rules:
              - alert: NodeNotReady
                expr: kube_node_status_condition{condition="Ready",status="true"} == 0
                for: 2m
                labels:
                  severity: critical
                annotations:
                  summary: "Node {{ $labels.node }} is not ready"
                  description: "Node {{ $labels.node }} has been not ready for more than 2 minutes. Single-node cluster — total outage."
              - alert: NodeFilesystemSpaceCritical
                expr: (node_filesystem_avail_bytes{mountpoint="/",fstype!=""} / node_filesystem_size_bytes{mountpoint="/",fstype!=""}) * 100 < 10
                for: 5m
                labels:
                  severity: critical
                annotations:
                  summary: "Root filesystem on {{ $labels.instance }} has less than 10% space"
                  description: "Root filesystem on {{ $labels.instance }} is {{ printf \"%.1f\" $value }}% free."
              - alert: NodeMemoryPressure
                expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 10
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "Node {{ $labels.instance }} has less than 10% memory available"
                  description: "Node {{ $labels.instance }} has {{ printf \"%.1f\" $value }}% memory available. OOMKiller may evict pods."
      workload-rules:
        groups:
          - name: workload.rules
            rules:
              - alert: PodCrashLooping
                expr: increase(kube_pod_container_status_restarts_total[10m]) > 3
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash-looping"
                  description: "Container {{ $labels.container }} in pod {{ $labels.namespace }}/{{ $labels.pod }} restarted {{ printf \"%.0f\" $value }} times in 10 minutes."
              - alert: PodNotReady
                expr: kube_pod_status_phase{phase=~"Pending|Unknown"} > 0
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is stuck in {{ $labels.phase }}"
                  description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} has been {{ $labels.phase }} for more than 10 minutes."
              - alert: PVCNearlyFull
                expr: (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 85
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is over 85% full"
                  description: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is {{ printf \"%.1f\" $value }}% used."
```

**Step 2: Validate**

Run: `mise run check`
Expected: All checks pass.

**Step 3: Commit**

```bash
git add kubernetes/infrastructure/monitoring/helmrelease-kube-prometheus-stack.yaml
git commit -m "feat(monitoring): add essential alert rules

Add 6 rules in 2 groups: node-rules (NodeNotReady, NodeFilesystemSpaceCritical,
NodeMemoryPressure) and workload-rules (PodCrashLooping, PodNotReady, PVCNearlyFull)."
```

---

## Task 3: Create Cluster Health Dashboard

A single-pane Grafana dashboard for at-a-glance cluster health. Provisioned as a ConfigMap with the `grafana_dashboard: "1"` label — Grafana's sidecar auto-discovers it.

**Files:**
- Create: `kubernetes/infrastructure/monitoring/grafana-dashboard-cluster-health.yaml`
- Modify: `kubernetes/infrastructure/monitoring/kustomization.yaml`

**Step 1: Create the dashboard ConfigMap**

Create `kubernetes/infrastructure/monitoring/grafana-dashboard-cluster-health.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-cluster-health
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  cluster-health.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "links": [],
      "panels": [
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
          "title": "Node Vitals",
          "type": "row"
        },
        {
          "type": "stat",
          "title": "CPU Usage",
          "gridPos": { "h": 4, "w": 8, "x": 0, "y": 1 },
          "targets": [
            {
              "expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "min": 0,
              "max": 100,
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 70 },
                  { "color": "red", "value": 90 }
                ]
              }
            },
            "overrides": []
          },
          "options": { "colorMode": "background", "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "type": "stat",
          "title": "Memory Usage",
          "gridPos": { "h": 4, "w": 8, "x": 8, "y": 1 },
          "targets": [
            {
              "expr": "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "min": 0,
              "max": 100,
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 70 },
                  { "color": "red", "value": 90 }
                ]
              }
            },
            "overrides": []
          },
          "options": { "colorMode": "background", "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "type": "stat",
          "title": "Root Disk Usage",
          "gridPos": { "h": 4, "w": 8, "x": 16, "y": 1 },
          "targets": [
            {
              "expr": "(1 - node_filesystem_avail_bytes{mountpoint=\"/\",fstype!=\"\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!=\"\"}) * 100",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "min": 0,
              "max": 100,
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 70 },
                  { "color": "red", "value": 90 }
                ]
              }
            },
            "overrides": []
          },
          "options": { "colorMode": "background", "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 5 },
          "title": "Workload Status",
          "type": "row"
        },
        {
          "type": "stat",
          "title": "Pods Running",
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 6 },
          "targets": [
            {
              "expr": "sum(kube_pod_status_phase{phase=\"Running\"})",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "mode": "absolute",
                "steps": [{ "color": "green", "value": null }]
              }
            },
            "overrides": []
          },
          "options": { "colorMode": "value", "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "type": "stat",
          "title": "Pods Not Ready",
          "gridPos": { "h": 4, "w": 6, "x": 6, "y": 6 },
          "targets": [
            {
              "expr": "sum(kube_pod_status_phase{phase=~\"Pending|Unknown\"}) or vector(0)",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "red", "value": 1 }
                ]
              }
            },
            "overrides": []
          },
          "options": { "colorMode": "background", "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "type": "stat",
          "title": "Crash-Looping Pods",
          "gridPos": { "h": 4, "w": 6, "x": 12, "y": 6 },
          "targets": [
            {
              "expr": "count(increase(kube_pod_container_status_restarts_total[10m]) > 3) or vector(0)",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "red", "value": 1 }
                ]
              }
            },
            "overrides": []
          },
          "options": { "colorMode": "background", "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "type": "table",
          "title": "Recent Restarts (last 1h)",
          "gridPos": { "h": 4, "w": 6, "x": 18, "y": 6 },
          "targets": [
            {
              "expr": "sort_desc(increase(kube_pod_container_status_restarts_total[1h]) > 0)",
              "refId": "A",
              "format": "table",
              "instant": true
            }
          ],
          "transformations": [
            {
              "id": "organize",
              "options": {
                "excludeByName": {
                  "Time": true,
                  "__name__": true,
                  "container": true,
                  "endpoint": true,
                  "instance": true,
                  "job": true,
                  "service": true,
                  "uid": true
                },
                "renameByName": {
                  "namespace": "Namespace",
                  "pod": "Pod",
                  "Value": "Restarts"
                }
              }
            }
          ],
          "fieldConfig": { "defaults": {}, "overrides": [] },
          "options": { "sortBy": [{ "displayName": "Restarts", "desc": true }] }
        },
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 10 },
          "title": "PVC Usage",
          "type": "row"
        },
        {
          "type": "bargauge",
          "title": "PersistentVolumeClaim Usage",
          "gridPos": { "h": 6, "w": 24, "x": 0, "y": 11 },
          "targets": [
            {
              "expr": "(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100",
              "refId": "A",
              "legendFormat": "{{ namespace }}/{{ persistentvolumeclaim }}"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "min": 0,
              "max": 100,
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 70 },
                  { "color": "red", "value": 85 }
                ]
              }
            },
            "overrides": []
          },
          "options": { "orientation": "horizontal", "displayMode": "gradient", "reduceOptions": { "calcs": ["lastNotNull"] } }
        },
        {
          "collapsed": false,
          "gridPos": { "h": 1, "w": 24, "x": 0, "y": 17 },
          "title": "Flux GitOps Sync",
          "type": "row"
        },
        {
          "type": "table",
          "title": "Kustomizations",
          "gridPos": { "h": 6, "w": 12, "x": 0, "y": 18 },
          "targets": [
            {
              "expr": "gotk_reconcile_condition{type=\"Ready\",kind=\"Kustomization\"}",
              "refId": "A",
              "format": "table",
              "instant": true
            }
          ],
          "transformations": [
            {
              "id": "organize",
              "options": {
                "excludeByName": {
                  "Time": true,
                  "__name__": true,
                  "endpoint": true,
                  "instance": true,
                  "job": true,
                  "pod": true,
                  "service": true,
                  "type": true,
                  "exported_namespace": false
                },
                "renameByName": {
                  "exported_namespace": "Namespace",
                  "name": "Name",
                  "status": "Ready",
                  "Value": "Active"
                }
              }
            }
          ],
          "fieldConfig": { "defaults": {}, "overrides": [] },
          "options": {}
        },
        {
          "type": "table",
          "title": "HelmReleases",
          "gridPos": { "h": 6, "w": 12, "x": 12, "y": 18 },
          "targets": [
            {
              "expr": "gotk_reconcile_condition{type=\"Ready\",kind=\"HelmRelease\"}",
              "refId": "A",
              "format": "table",
              "instant": true
            }
          ],
          "transformations": [
            {
              "id": "organize",
              "options": {
                "excludeByName": {
                  "Time": true,
                  "__name__": true,
                  "endpoint": true,
                  "instance": true,
                  "job": true,
                  "pod": true,
                  "service": true,
                  "type": true,
                  "exported_namespace": false
                },
                "renameByName": {
                  "exported_namespace": "Namespace",
                  "name": "Name",
                  "status": "Ready",
                  "Value": "Active"
                }
              }
            }
          ],
          "fieldConfig": { "defaults": {}, "overrides": [] },
          "options": {}
        }
      ],
      "refresh": "30s",
      "schemaVersion": 39,
      "tags": ["cloudlab", "cluster-health"],
      "templating": { "list": [] },
      "time": { "from": "now-6h", "to": "now" },
      "title": "Cluster Health",
      "uid": "cloudlab-cluster-health"
    }
```

**Step 2: Register the ConfigMap in kustomization.yaml**

Add `grafana-dashboard-cluster-health.yaml` to the resource list in `kubernetes/infrastructure/monitoring/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository-prometheus-community.yaml
  - helmrepository-grafana.yaml
  - secret.enc.yaml
  - helmrelease-kube-prometheus-stack.yaml
  - helmrelease-loki.yaml
  - helmrelease-alloy.yaml
  - grafana-datasource-loki.yaml
  - grafana-dashboard-cluster-health.yaml
```

**Step 3: Validate**

Run: `mise run check`
Expected: All checks pass. Kubeconform validates the new ConfigMap.

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/monitoring/grafana-dashboard-cluster-health.yaml kubernetes/infrastructure/monitoring/kustomization.yaml
git commit -m "feat(monitoring): add cluster health Grafana dashboard

Single-pane overview: node vitals (CPU, memory, disk), workload status
(pods running, not ready, crash-looping), PVC usage, Flux sync state."
```

---

## Task 4: Create Log Explorer Dashboard

A Loki-backed dashboard for investigating alerts. Template variables for namespace, pod, and search text.

**Files:**
- Create: `kubernetes/infrastructure/monitoring/grafana-dashboard-log-explorer.yaml`
- Modify: `kubernetes/infrastructure/monitoring/kustomization.yaml`

**Step 1: Create the dashboard ConfigMap**

Create `kubernetes/infrastructure/monitoring/grafana-dashboard-log-explorer.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-log-explorer
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  log-explorer.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "links": [],
      "panels": [
        {
          "type": "timeseries",
          "title": "Log Volume",
          "gridPos": { "h": 6, "w": 24, "x": 0, "y": 0 },
          "datasource": { "type": "loki", "uid": "loki" },
          "targets": [
            {
              "expr": "sum by (level) (count_over_time({namespace=~\"$namespace\", pod=~\"$pod\"} |~ \"$search\" [1m]))",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "custom": {
                "drawStyle": "bars",
                "stacking": { "mode": "normal" },
                "fillOpacity": 80
              }
            },
            "overrides": [
              {
                "matcher": { "id": "byName", "options": "error" },
                "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }]
              },
              {
                "matcher": { "id": "byName", "options": "warn" },
                "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }]
              },
              {
                "matcher": { "id": "byName", "options": "info" },
                "properties": [{ "id": "color", "value": { "fixedColor": "blue", "mode": "fixed" } }]
              }
            ]
          },
          "options": { "tooltip": { "mode": "multi" } }
        },
        {
          "type": "logs",
          "title": "Log Stream",
          "gridPos": { "h": 16, "w": 24, "x": 0, "y": 6 },
          "datasource": { "type": "loki", "uid": "loki" },
          "targets": [
            {
              "expr": "{namespace=~\"$namespace\", pod=~\"$pod\"} |~ \"$search\"",
              "refId": "A"
            }
          ],
          "options": {
            "showTime": true,
            "showLabels": true,
            "showCommonLabels": false,
            "wrapLogMessage": true,
            "prettifyLogMessage": false,
            "enableLogDetails": true,
            "sortOrder": "Descending",
            "dedupStrategy": "none"
          }
        }
      ],
      "refresh": "10s",
      "schemaVersion": 39,
      "tags": ["cloudlab", "logs"],
      "templating": {
        "list": [
          {
            "name": "namespace",
            "type": "query",
            "datasource": { "type": "loki", "uid": "loki" },
            "query": { "label": "namespace", "type": 1 },
            "refresh": 2,
            "includeAll": true,
            "allValue": ".*",
            "current": { "text": "All", "value": "$__all" },
            "sort": 1
          },
          {
            "name": "pod",
            "type": "query",
            "datasource": { "type": "loki", "uid": "loki" },
            "query": { "label": "pod", "type": 1, "stream": "{namespace=~\"$namespace\"}" },
            "refresh": 2,
            "includeAll": true,
            "allValue": ".*",
            "current": { "text": "All", "value": "$__all" },
            "sort": 1
          },
          {
            "name": "search",
            "type": "textbox",
            "current": { "text": "", "value": "" },
            "label": "Search"
          }
        ]
      },
      "time": { "from": "now-1h", "to": "now" },
      "title": "Log Explorer",
      "uid": "cloudlab-log-explorer"
    }
```

**Step 2: Register in kustomization.yaml**

Add `grafana-dashboard-log-explorer.yaml` to the resource list:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository-prometheus-community.yaml
  - helmrepository-grafana.yaml
  - secret.enc.yaml
  - helmrelease-kube-prometheus-stack.yaml
  - helmrelease-loki.yaml
  - helmrelease-alloy.yaml
  - grafana-datasource-loki.yaml
  - grafana-dashboard-cluster-health.yaml
  - grafana-dashboard-log-explorer.yaml
```

**Step 3: Validate**

Run: `mise run check`
Expected: All checks pass.

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/monitoring/grafana-dashboard-log-explorer.yaml kubernetes/infrastructure/monitoring/kustomization.yaml
git commit -m "feat(monitoring): add log explorer Grafana dashboard

Loki-backed dashboard with namespace/pod/search filters. Log volume
histogram and log stream panel for quick alert investigation."
```

---

## Task 5: Deploy Headlamp

Headlamp provides a web UI for browsing Kubernetes objects. Deployed as a HelmRelease in `kubernetes/apps/headlamp/` with read-only RBAC. Authentik forward-auth covers access via the Kyverno policy.

**Chart details:**
- Repository: `https://kubernetes-sigs.github.io/headlamp/`
- Chart: `headlamp`
- Version: `0.40.0`
- Key values: `clusterRoleBinding.clusterRoleName: view` for read-only

**Files:**
- Create: `kubernetes/apps/headlamp/namespace.yaml`
- Create: `kubernetes/apps/headlamp/helmrepository.yaml`
- Create: `kubernetes/apps/headlamp/helmrelease.yaml`
- Create: `kubernetes/apps/headlamp/httproute.yaml`
- Create: `kubernetes/apps/headlamp/kustomization.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Step 1: Create namespace**

Create `kubernetes/apps/headlamp/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: headlamp
```

**Step 2: Create HelmRepository**

Create `kubernetes/apps/headlamp/helmrepository.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: headlamp
  namespace: headlamp
spec:
  interval: 60m
  url: https://kubernetes-sigs.github.io/headlamp/
```

**Step 3: Create HelmRelease**

Create `kubernetes/apps/headlamp/helmrelease.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: headlamp
  namespace: headlamp
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: headlamp
      version: "0.40.0"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: headlamp
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    clusterRoleBinding:
      create: true
      clusterRoleName: view
    config:
      inCluster: true
    service:
      type: ClusterIP
      port: 80
    securityContext:
      runAsNonRoot: true
      privileged: false
      runAsUser: 100
      runAsGroup: 101
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 128Mi
```

**Step 4: Create HTTPRoute**

Create `kubernetes/apps/headlamp/httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: headlamp
  namespace: headlamp
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "headlamp.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: headlamp
          port: 80
```

**Step 5: Create kustomization.yaml**

Create `kubernetes/apps/headlamp/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
  - httproute.yaml
```

**Step 6: Register in apps kustomization**

Update `kubernetes/apps/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - whoami
  - headlamp
```

**Step 7: Validate**

Run: `mise run check`
Expected: All checks pass. Kubeconform validates all new resources.

**Step 8: Commit**

```bash
git add kubernetes/apps/headlamp/ kubernetes/apps/kustomization.yaml
git commit -m "feat(apps): deploy Headlamp Kubernetes dashboard

Read-only cluster browser (view ClusterRole) behind Authentik forward-auth.
Chart v0.40.0, accessible at headlamp.catinthehack.ca."
```

---

## Task 6: Update Documentation

Update CLAUDE.md, ARCHITECTURE.md, and README.md to reflect the new components.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `ARCHITECTURE.md`
- Modify: `README.md`

**Step 1: Update CLAUDE.md**

Add to the **Key Files** table:

```
| `kubernetes/apps/headlamp/` | Headlamp Kubernetes dashboard (read-only cluster browser) |
```

Add to **Implementation Notes**:

```
- **Pushover notification templates**: HelmRelease values are data, not Helm templates. Use direct Go template syntax (`{{ .CommonLabels.alertname }}`) in Alertmanager receiver configs — do NOT escape with `{{ "{{" }}`. Named templates defined in `alertmanager.templateFiles` keep the receiver config clean.
- **Grafana dashboard provisioning**: Dashboards defined as JSON inside ConfigMaps labeled `grafana_dashboard: "1"`. Grafana's sidecar auto-discovers them in the monitoring namespace. Same mechanism as datasource auto-discovery.
- **Headlamp auth**: Behind Authentik forward-auth via Kyverno policy. Headlamp's own login requires a ServiceAccount token — generate with `kubectl create token headlamp-headlamp -n headlamp --duration=8760h` and paste into the UI once. Browser stores the token in localStorage.
- **Headlamp read-only RBAC**: Uses the built-in `view` ClusterRole via `clusterRoleBinding.clusterRoleName: view`. Read access to all namespaces, no write operations.
```

Add to **Deployment Lessons** under a new subsection **Alerting and notifications**:

```
### Alerting and notifications
- **Do not escape Go templates in HelmRelease values.** `{{ "{{" }}` is Helm chart template escaping, not HelmRelease values escaping. Values are data — Flux and Helm pass them through without template processing. Use `{{ .CommonLabels.alertname }}` directly. The double-escaping produces literal template text in Alertmanager output.
- **Use `templateFiles` for complex Alertmanager notification formatting.** Define named templates in `alertmanager.templateFiles` and reference them via `{{ template "name" . }}` in receiver configs. Cleaner than inline template logic.
- **Start with few alert rules and expand.** A noisy alerting setup trains operators to ignore alerts. Begin with 8-10 rules covering critical failures (node down, disk full, crash loops), then add warning-tier rules based on observed gaps.
```

**Step 2: Update ARCHITECTURE.md**

Add Headlamp to the **Apps** section:

```
### Apps

Each app follows the pattern: namespace, Deployment, Service, HTTPRoute, Kustomize entry point. The whoami app demonstrates this pattern. Register new apps in `kubernetes/apps/kustomization.yaml`.

| App | Purpose |
|-----|---------|
| whoami | Smoke test — validates ingress, TLS, and Gateway routing |
| Headlamp | Read-only Kubernetes dashboard for visual cluster browsing and triage |
```

Add to the **Infrastructure components** table:

Update the Monitoring row description to mention alert rules and dashboards:

```
| Monitoring | Prometheus, Grafana (custom dashboards), Alertmanager (Pushover), Loki, Alloy |
```

**Step 3: Update README.md roadmap**

Strike through step 26 (Headlamp) since it is now implemented. Move it conceptually from Phase 4 to "done":

Change line 144:
```
26. ~~**Cluster dashboard** — Headlamp for visual cluster inspection behind auth~~
```

**Step 4: Validate**

Run: `mise run check`
Expected: All checks pass (docs don't affect validation, but ensures no formatting issues in YAML).

**Step 5: Commit**

```bash
git add CLAUDE.md ARCHITECTURE.md README.md
git commit -m "docs: add observability tuning and Headlamp implementation notes

Update CLAUDE.md with Pushover template, dashboard provisioning, and
Headlamp auth notes. Add Headlamp to ARCHITECTURE.md apps table.
Strike through step 26 in README.md roadmap."
```

---

## Post-Deploy Verification (manual, after Flux reconciles)

These steps require a running cluster. Run after pushing the branch and merging, or after `flux reconcile`:

1. **Pushover template**: Trigger a test alert via Alertmanager API or silence/unsilence Watchdog. Confirm phone notification shows `[FIRING] Watchdog` as title, not raw template syntax.

2. **Alert rules**: Check Prometheus UI → Status → Rules. Confirm `node.rules` and `workload.rules` groups appear with all 6 new rules.

3. **Cluster health dashboard**: Open Grafana → Dashboards → search "Cluster Health". Confirm 4 rows render with data. All stat panels should show green (healthy cluster).

4. **Log explorer dashboard**: Open Grafana → Dashboards → search "Log Explorer". Select a namespace from the dropdown. Confirm log volume histogram and log stream populate.

5. **Headlamp**: Navigate to `headlamp.catinthehack.ca`. Confirm Authentik login prompt appears. After auth, generate a token: `kubectl create token headlamp-headlamp -n headlamp --duration=8760h`. Paste into Headlamp. Confirm read-only cluster browsing works.
