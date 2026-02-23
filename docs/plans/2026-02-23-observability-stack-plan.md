# Observability Stack Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy a unified observability stack — metrics, logs, and alerting — with Pushover notifications and Grafana as the single interface.

**Architecture:** kube-prometheus-stack provides Prometheus, Grafana, Alertmanager, and pre-built dashboards. Loki aggregates logs in single-binary mode. Alloy collects container logs and ships them to Loki. Flux notification-controller pushes GitOps events to Alertmanager. All components share the `monitoring` namespace and use NFS-backed persistent storage.

**Tech Stack:** kube-prometheus-stack (chart 82.x), Loki (chart 6.x), Alloy (chart 1.x), Flux notification-controller, SOPS, Kustomize, Gateway API HTTPRoutes.

**Design doc:** `docs/plans/2026-02-23-observability-stack-design.md`

**Worktree:** `.worktrees/feat/observability-stack` (branch `feat/observability-stack`)

**Validation command:** `mise run check` (runs terraform fmt/validate/lint, kustomize build + kubeconform, gitleaks)

---

## Task 1: Create monitoring namespace and HelmRepository

**Files:**
- Create: `kubernetes/infrastructure/monitoring/namespace.yaml`
- Create: `kubernetes/infrastructure/monitoring/helmrepository.yaml`
- Create: `kubernetes/infrastructure/monitoring/kustomization.yaml`

**Step 1: Create the namespace**

```yaml
# kubernetes/infrastructure/monitoring/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
```

**Step 2: Create the HelmRepository for prometheus-community**

```yaml
# kubernetes/infrastructure/monitoring/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: monitoring
spec:
  interval: 60m
  url: https://prometheus-community.github.io/helm-charts
```

**Step 3: Create the Kustomize entry point**

```yaml
# kubernetes/infrastructure/monitoring/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
```

**Step 4: Register monitoring in the parent kustomization**

Edit `kubernetes/infrastructure/kustomization.yaml` — add `monitoring` to the resources list.

**Step 5: Run validation**

Run: `mise run check`
Expected: all checks pass, monitoring resources appear in kubeconform output for `kubernetes/infrastructure/`.

**Step 6: Commit**

```bash
git add kubernetes/infrastructure/monitoring/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(monitoring): add namespace and prometheus-community HelmRepository"
```

---

## Task 2: Create SOPS-encrypted secret for Pushover and Grafana credentials

**Files:**
- Create: `kubernetes/infrastructure/monitoring/secret.enc.yaml`
- Modify: `kubernetes/infrastructure/monitoring/kustomization.yaml`

**Prerequisites:** The user must provide Pushover user key and API token. Grafana admin password must be chosen.

**Step 1: Create the plaintext secret**

```yaml
# kubernetes/infrastructure/monitoring/secret.enc.yaml (before encryption)
apiVersion: v1
kind: Secret
metadata:
  name: monitoring-secrets
  namespace: monitoring
type: Opaque
stringData:
  pushover-user-key: "<USER_KEY>"
  pushover-api-token: "<API_TOKEN>"
  grafana-admin-password: "<ADMIN_PASSWORD>"
```

**Step 2: Encrypt the secret with SOPS**

Run: `sops encrypt -i kubernetes/infrastructure/monitoring/secret.enc.yaml`
Expected: all `stringData` values replaced with `ENC[AES256_GCM,...]` markers, `sops:` metadata block appended.

**Step 3: Add to kustomization**

Edit `kubernetes/infrastructure/monitoring/kustomization.yaml` — add `secret.enc.yaml` to resources.

**Step 4: Run validation**

Run: `mise run check`
Expected: all checks pass. The SOPS-encrypted secret passes kubeconform after the awk filter strips `sops:` metadata.

**Step 5: Commit**

```bash
git add kubernetes/infrastructure/monitoring/secret.enc.yaml kubernetes/infrastructure/monitoring/kustomization.yaml
git commit -m "feat(monitoring): add SOPS-encrypted Pushover and Grafana credentials"
```

---

## Task 3: Create kube-prometheus-stack HelmRelease

**Files:**
- Create: `kubernetes/infrastructure/monitoring/helmrelease.yaml`
- Modify: `kubernetes/infrastructure/monitoring/kustomization.yaml`

**Step 1: Create the HelmRelease**

```yaml
# kubernetes/infrastructure/monitoring/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  interval: 30m
  timeout: 10m
  chart:
    spec:
      chart: kube-prometheus-stack
      version: "82.x.x"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    # Prometheus
    prometheus:
      prometheusSpec:
        retention: 7d
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: nfs
              accessModes:
                - ReadWriteOnce
              resources:
                requests:
                  storage: 10Gi
        additionalPrometheusRulesMap:
          flux-rules:
            groups:
              - name: flux.rules
                rules:
                  - alert: FluxReconciliationFailure
                    expr: gotk_reconcile_condition{type="Ready",status="False"} == 1
                    for: 5m
                    labels:
                      severity: warning
                    annotations:
                      summary: "Flux {{ $labels.kind }}/{{ $labels.name }} reconciliation failed"
                      description: "{{ $labels.kind }}/{{ $labels.name }} in namespace {{ $labels.exported_namespace }} has been failing for more than 5 minutes."
          cert-manager-rules:
            groups:
              - name: cert-manager.rules
                rules:
                  - alert: CertManagerCertExpirySoon
                    expr: certmanager_certificate_expiration_timestamp_seconds - time() < 604800
                    for: 1h
                    labels:
                      severity: warning
                    annotations:
                      summary: "Certificate {{ $labels.name }} expires in less than 7 days"
                      description: "Certificate {{ $labels.name }} in namespace {{ $labels.namespace }} expires in {{ $value | humanizeDuration }}."

    # Alertmanager
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
      config:
        global:
          resolve_timeout: 5m
        route:
          receiver: pushover-warning
          group_by:
            - alertname
            - namespace
          group_wait: 30s
          group_interval: 5m
          repeat_interval: 12h
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
                retry: 300s
                expire: 3600s
                title: '{{ "{{" }} .CommonLabels.alertname {{ "}}" }}'
                message: '{{ "{{" }} range .Alerts {{ "}}" }}{{ "{{" }} .Annotations.summary {{ "}}" }}{{ "{{" }} end {{ "}}" }}'
          - name: pushover-warning
            pushover_configs:
              - user_key_file: /etc/alertmanager/secrets/monitoring-secrets/pushover-user-key
                token_file: /etc/alertmanager/secrets/monitoring-secrets/pushover-api-token
                priority: "0"
                title: '{{ "{{" }} .CommonLabels.alertname {{ "}}" }}'
                message: '{{ "{{" }} range .Alerts {{ "}}" }}{{ "{{" }} .Annotations.summary {{ "}}" }}{{ "{{" }} end {{ "}}" }}'
      secrets:
        - monitoring-secrets

    # Grafana
    grafana:
      admin:
        existingSecret: monitoring-secrets
        userKey: grafana-admin-user
        passwordKey: grafana-admin-password
      persistence:
        enabled: true
        storageClassName: nfs
        size: 1Gi
      sidecar:
        datasources:
          enabled: true
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi

    # Thanos — disabled
    prometheus:
      thanosService:
        enabled: false
      thanosServiceMonitor:
        enabled: false

    # node-exporter
    nodeExporter:
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 64Mi

    # kube-state-metrics
    kube-state-metrics:
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 64Mi
```

**Important:** Pin to the exact latest chart version at implementation time. Check `helm search repo prometheus-community/kube-prometheus-stack --versions | head -1` or use the version from research (82.2.1). Replace `"82.x.x"` with the exact version.

**Note on Pushover credentials:** kube-prometheus-stack's Alertmanager supports mounting Secrets via `alertmanager.secrets`. The Secret is mounted at `/etc/alertmanager/secrets/<secret-name>/`. The `user_key_file` and `token_file` fields read credentials from those mounted files — this avoids putting secrets directly in the Alertmanager config.

**Note on Grafana admin:** The `existingSecret` must contain keys matching `userKey` and `passwordKey`. Add `grafana-admin-user: admin` to the Secret's `stringData` in Task 2.

**Step 2: Add to kustomization**

Edit `kubernetes/infrastructure/monitoring/kustomization.yaml` — add `helmrelease.yaml` to resources.

**Step 3: Run validation**

Run: `mise run check`
Expected: all checks pass. The HelmRelease resource validates via kubeconform.

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/monitoring/helmrelease.yaml kubernetes/infrastructure/monitoring/kustomization.yaml
git commit -m "feat(monitoring): add kube-prometheus-stack HelmRelease with Pushover alerting"
```

---

## Task 4: Create HTTPRoutes for Grafana, Prometheus, and Alertmanager

**Files:**
- Create: `kubernetes/infrastructure/monitoring/httproute-grafana.yaml`
- Create: `kubernetes/infrastructure/monitoring/httproute-prometheus.yaml`
- Create: `kubernetes/infrastructure/monitoring/httproute-alertmanager.yaml`
- Modify: `kubernetes/infrastructure/monitoring/kustomization.yaml`

**Step 1: Create the Grafana HTTPRoute**

```yaml
# kubernetes/infrastructure/monitoring/httproute-grafana.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "grafana.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: kube-prometheus-stack-grafana
          port: 80
```

**Note:** The Grafana service name follows kube-prometheus-stack's naming convention: `<release-name>-grafana`. Since the HelmRelease is named `kube-prometheus-stack`, the service is `kube-prometheus-stack-grafana`. Verify this after deployment with `kubectl get svc -n monitoring`.

**Step 2: Create the Prometheus HTTPRoute**

```yaml
# kubernetes/infrastructure/monitoring/httproute-prometheus.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: prometheus
  namespace: monitoring
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "prometheus.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: kube-prometheus-stack-prometheus
          port: 9090
```

**Step 3: Create the Alertmanager HTTPRoute**

```yaml
# kubernetes/infrastructure/monitoring/httproute-alertmanager.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "alertmanager.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: kube-prometheus-stack-alertmanager
          port: 9093
```

**Step 4: Add to kustomization**

Edit `kubernetes/infrastructure/monitoring/kustomization.yaml` — add all three HTTPRoute files to resources.

**Step 5: Run validation**

Run: `mise run check`
Expected: all checks pass. HTTPRoute resources validate via kubeconform.

**Step 6: Commit**

```bash
git add kubernetes/infrastructure/monitoring/httproute-*.yaml kubernetes/infrastructure/monitoring/kustomization.yaml
git commit -m "feat(monitoring): add HTTPRoutes for Grafana, Prometheus, and Alertmanager"
```

---

## Task 5: Create Loki HelmRepository, HelmRelease, and Grafana datasource

**Files:**
- Create: `kubernetes/infrastructure/loki/namespace.yaml`
- Create: `kubernetes/infrastructure/loki/helmrepository.yaml`
- Create: `kubernetes/infrastructure/loki/helmrelease.yaml`
- Create: `kubernetes/infrastructure/loki/grafana-datasource.yaml`
- Create: `kubernetes/infrastructure/loki/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create the namespace**

Loki shares the `monitoring` namespace. Create a namespace reference that points to the same namespace — or skip a dedicated namespace file and reference the monitoring namespace directly.

Actually, per the design, all components share the `monitoring` namespace. Loki does not need its own namespace file. Set all Loki resources to `namespace: monitoring`.

```yaml
# kubernetes/infrastructure/loki/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: grafana
  namespace: monitoring
spec:
  interval: 60m
  url: https://grafana.github.io/helm-charts
```

**Step 2: Create the HelmRelease**

```yaml
# kubernetes/infrastructure/loki/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: loki
  namespace: monitoring
spec:
  interval: 30m
  timeout: 10m
  dependsOn:
    - name: kube-prometheus-stack
  chart:
    spec:
      chart: loki
      version: "6.x.x"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: grafana
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    deploymentMode: SingleBinary
    singleBinary:
      replicas: 1
      resources:
        requests:
          cpu: 50m
          memory: 256Mi
        limits:
          memory: 512Mi
      persistence:
        storageClass: nfs
        size: 10Gi
    # Zero out all other deployment modes
    backend:
      replicas: 0
    read:
      replicas: 0
    write:
      replicas: 0
    # Loki config
    loki:
      auth_enabled: false
      commonConfig:
        replication_factor: 1
      limits_config:
        retention_period: 168h
      schemaConfig:
        configs:
          - from: "2024-04-01"
            store: tsdb
            object_store: filesystem
            schema: v13
            index:
              prefix: loki_index_
              period: 24h
      storage:
        type: filesystem
    # Disable built-in gateway (Grafana queries directly)
    gateway:
      enabled: false
    # Disable minio (using filesystem storage)
    minio:
      enabled: false
    # Disable self-monitoring
    monitoring:
      selfMonitoring:
        enabled: false
      lokiCanary:
        enabled: false
```

**Important:** Pin to the exact latest chart version at implementation time. Replace `"6.x.x"` with the exact version (e.g., 6.53.0).

**Step 3: Create the Grafana datasource ConfigMap**

kube-prometheus-stack's Grafana sidecar watches for ConfigMaps with the label `grafana_datasource: "1"` and auto-registers them as datasources.

```yaml
# kubernetes/infrastructure/loki/grafana-datasource.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.monitoring.svc:3100
        isDefault: false
```

**Step 4: Create the Kustomize entry point**

```yaml
# kubernetes/infrastructure/loki/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrepository.yaml
  - helmrelease.yaml
  - grafana-datasource.yaml
```

**Step 5: Register loki in the parent kustomization**

Edit `kubernetes/infrastructure/kustomization.yaml` — add `loki` to the resources list.

**Step 6: Run validation**

Run: `mise run check`
Expected: all checks pass. Loki resources appear in kubeconform output.

**Step 7: Commit**

```bash
git add kubernetes/infrastructure/loki/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(loki): add Loki single-binary with Grafana datasource auto-discovery"
```

---

## Task 6: Create Alloy HelmRelease and HTTPRoute

**Files:**
- Create: `kubernetes/infrastructure/alloy/helmrelease.yaml`
- Create: `kubernetes/infrastructure/alloy/httproute-alloy.yaml`
- Create: `kubernetes/infrastructure/alloy/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create the HelmRelease**

```yaml
# kubernetes/infrastructure/alloy/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: alloy
  namespace: monitoring
spec:
  interval: 30m
  timeout: 5m
  dependsOn:
    - name: loki
  chart:
    spec:
      chart: alloy
      version: "1.x.x"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: grafana
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    alloy:
      configMap:
        create: true
      clustering:
        enabled: false
      mounts:
        varlog: true
    controller:
      type: daemonset
    resources:
      requests:
        cpu: 20m
        memory: 128Mi
      limits:
        memory: 256Mi
    alloy:
      config: |
        // Discover Kubernetes pods on this node
        discovery.kubernetes "pods" {
          role = "pod"
          selectors {
            role = "pod"
            field = "spec.nodeName=" + coalesce(sys.env("HOSTNAME"), constants.hostname)
          }
        }

        // Relabel pod metadata into log labels
        discovery.relabel "pod_logs" {
          targets = discovery.kubernetes.pods.targets

          rule {
            source_labels = ["__meta_kubernetes_namespace"]
            action        = "replace"
            target_label  = "namespace"
          }

          rule {
            source_labels = ["__meta_kubernetes_pod_name"]
            action        = "replace"
            target_label  = "pod"
          }

          rule {
            source_labels = ["__meta_kubernetes_pod_container_name"]
            action        = "replace"
            target_label  = "container"
          }

          rule {
            source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
            action        = "replace"
            target_label  = "app"
          }

          rule {
            source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_container_name"]
            action        = "replace"
            target_label  = "job"
            separator     = "/"
          }

          rule {
            source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
            action        = "replace"
            target_label  = "__path__"
            separator     = "/"
            replacement   = "/var/log/pods/*$1/*.log"
          }
        }

        // Collect logs from Kubernetes pods
        loki.source.kubernetes "pod_logs" {
          targets    = discovery.relabel.pod_logs.output
          forward_to = [loki.process.pod_logs.receiver]
        }

        // Add cluster label
        loki.process "pod_logs" {
          stage.static_labels {
            values = {
              cluster = "cloudlab",
            }
          }
          forward_to = [loki.write.default.receiver]
        }

        // Ship to Loki
        loki.write "default" {
          endpoint {
            url = "http://loki.monitoring.svc:3100/loki/api/v1/push"
          }
        }
```

**Important:** Pin to the exact latest chart version. Replace `"1.x.x"` with the exact version (e.g., 1.6.0).

**Note on Alloy config placement:** The Alloy Helm chart accepts River config via `alloy.config` in values. The exact values path may vary by chart version — verify with `helm show values grafana/alloy | grep -A5 config` at implementation time. Adjust the path if the chart uses a different key (e.g., `alloy.configMap.content`).

**Step 2: Create the Alloy HTTPRoute**

```yaml
# kubernetes/infrastructure/alloy/httproute-alloy.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: alloy
  namespace: monitoring
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "alloy.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: alloy
          port: 12345
```

**Note:** Alloy's default UI port is 12345. Verify with `kubectl get svc -n monitoring` after deployment.

**Step 3: Create the Kustomize entry point**

```yaml
# kubernetes/infrastructure/alloy/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - httproute-alloy.yaml
```

**Step 4: Register alloy in the parent kustomization**

Edit `kubernetes/infrastructure/kustomization.yaml` — add `alloy` to the resources list.

**Step 5: Run validation**

Run: `mise run check`
Expected: all checks pass.

**Step 6: Commit**

```bash
git add kubernetes/infrastructure/alloy/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(alloy): add Alloy DaemonSet for Kubernetes log collection"
```

---

## Task 7: Create Flux notification Provider and Alert

**Files:**
- Create: `kubernetes/flux-system/provider-alertmanager.yaml`
- Create: `kubernetes/flux-system/alert-flux.yaml`
- Modify: `kubernetes/flux-system/kustomization.yaml`

**Step 1: Create the Alertmanager Provider**

```yaml
# kubernetes/flux-system/provider-alertmanager.yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: alertmanager
  namespace: flux-system
spec:
  type: alertmanager
  address: http://kube-prometheus-stack-alertmanager.monitoring.svc:9093/api/v2/alerts
```

**Note:** No authentication needed — cluster-internal traffic. The address uses the service DNS name in the monitoring namespace.

**Step 2: Create the Alert resource**

```yaml
# kubernetes/flux-system/alert-flux.yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: flux-alerts
  namespace: flux-system
spec:
  providerRef:
    name: alertmanager
  eventSeverity: error
  eventSources:
    - kind: GitRepository
      name: "*"
    - kind: Kustomization
      name: "*"
    - kind: HelmRelease
      name: "*"
    - kind: HelmRepository
      name: "*"
```

**Step 3: Add to flux-system kustomization**

Edit `kubernetes/flux-system/kustomization.yaml` — add `provider-alertmanager.yaml` and `alert-flux.yaml` to the resources list.

**Step 4: Run validation**

Run: `mise run check`
Expected: all checks pass. Provider and Alert resources appear in kubeconform output for `kubernetes/flux-system/`.

**Step 5: Commit**

```bash
git add kubernetes/flux-system/provider-alertmanager.yaml kubernetes/flux-system/alert-flux.yaml kubernetes/flux-system/kustomization.yaml
git commit -m "feat(flux): add Alertmanager provider and alert for GitOps failure notifications"
```

---

## Task 8: Update /etc/hosts and validate the full stack

**Prerequisites:** All previous tasks committed and pushed. Flux has reconciled the changes on the cluster.

**Step 1: Add /etc/hosts entries**

Add to `/etc/hosts` on the developer machine:

```
192.168.20.100  grafana.catinthehack.ca
192.168.20.100  prometheus.catinthehack.ca
192.168.20.100  alertmanager.catinthehack.ca
192.168.20.100  alloy.catinthehack.ca
```

**Step 2: Verify Flux reconciliation**

Run: `flux get kustomizations`
Expected: `infrastructure` shows `Ready: True`.

Run: `flux get helmreleases -n monitoring`
Expected: `kube-prometheus-stack`, `loki`, and `alloy` all show `Ready: True`.

**Step 3: Verify Prometheus targets**

Open: `https://prometheus.catinthehack.ca/targets`
Expected: all scrape targets show `UP` (green).

**Step 4: Verify Grafana**

Open: `https://grafana.catinthehack.ca`
Expected: login page loads. Sign in with admin credentials from the SOPS secret.
Check: datasources page shows both `Prometheus` (default) and `Loki`.
Check: default dashboards load with data (node health, pod resources, etc.).

**Step 5: Verify Loki logs**

In Grafana: navigate to Explore, select Loki datasource.
Run query: `{namespace="monitoring"}`
Expected: log lines from monitoring namespace pods.

**Step 6: Verify Alloy pipeline**

Open: `https://alloy.catinthehack.ca`
Expected: pipeline graph shows healthy components (green).

**Step 7: Verify Alertmanager**

Open: `https://alertmanager.catinthehack.ca`
Expected: Alertmanager UI loads. Pushover receivers visible in Status > Config.

**Step 8: Test Pushover notification**

In Alertmanager UI: create a test alert or use `amtool`:

Run: `kubectl exec -n monitoring deploy/kube-prometheus-stack-alertmanager -- amtool alert add test-alert severity=warning --alertmanager.url=http://localhost:9093`
Expected: Pushover notification on mobile device.

**Step 9: Test Flux notification path**

Deliberately break a Kustomization (e.g., add an invalid resource reference), push the change, wait for Flux to detect the failure.
Expected: alert appears in Alertmanager from the Flux notification-controller Provider.
Clean up: revert the deliberate break.

---

## Task 9: Update documentation

**Files:**
- Modify: `CLAUDE.md` — add implementation notes for observability stack
- Modify: `README.md` — update roadmap (strike through steps 8-10, add Thanos to Phase 4)

**Step 1: Update CLAUDE.md**

Add to the Implementation Notes section:

- **Observability namespace**: All monitoring components (Prometheus, Grafana, Alertmanager, Loki, Alloy) share the `monitoring` namespace. No component has its own namespace.
- **Grafana datasource auto-discovery**: kube-prometheus-stack's Grafana sidecar watches for ConfigMaps labeled `grafana_datasource: "1"` in the monitoring namespace. Loki registers via this mechanism.
- **Alertmanager Pushover credentials**: Mounted from the `monitoring-secrets` Secret via `alertmanager.secrets` in kube-prometheus-stack values. Credentials read from files at `/etc/alertmanager/secrets/monitoring-secrets/`.
- **Alloy River config**: Embedded in HelmRelease values. Uses `loki.source.kubernetes` for pod log collection with label enrichment (namespace, pod, container, app).
- **Flux notification-controller**: Provider (type: alertmanager) and Alert resources in `flux-system/` push GitOps events to Alertmanager. Second signal path alongside Prometheus scraping Flux metrics.
- **Loki storage**: Filesystem-backed in single-binary mode. No object storage (MinIO/S3) needed for homelab scale.
- **Exposed UIs without auth**: Grafana has built-in login. Prometheus, Alertmanager, and Alloy have no authentication — first candidates for the auth gateway (step 12).

**Step 2: Update README.md roadmap**

Strike through steps 8, 9, 10 as completed. Update step 9 description from "Promtail" to "Alloy". Add Thanos to Phase 4.

**Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: add observability stack implementation notes and update roadmap"
```

---

## Task 10: Run final validation and create PR

**Step 1: Run full validation**

Run: `mise run check`
Expected: all checks pass.

**Step 2: Review all changes**

Run: `git log --oneline main..HEAD`
Expected: all commits from tasks 1-9 listed.

Run: `git diff main..HEAD --stat`
Expected: new files in `kubernetes/infrastructure/monitoring/`, `kubernetes/infrastructure/loki/`, `kubernetes/infrastructure/alloy/`, modifications to parent kustomizations, Flux resources, and documentation.

**Step 3: Push and create PR**

```bash
git push -u origin feat/observability-stack
```

Create PR with title: `feat: add observability stack (Prometheus, Loki, Alloy, alerting)`

Body should summarize:
- What was added (kube-prometheus-stack, Loki, Alloy, Flux notifications)
- HTTPRoutes for all four UIs
- Pushover alerting with critical/warning routing
- Custom PrometheusRules for Flux and cert-manager
- 7-day retention, NFS-backed storage
