# Internal DNS Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy AdGuard Home and Unbound as the network's DNS server, resolving `*.catinthehack.ca` to `192.168.20.100` with recursive DNS and ad-blocking.

**Architecture:** Two Helm charts in a shared `adguard` namespace. Unbound resolves queries recursively against root nameservers, bypassing third-party forwarders. AdGuard Home faces the network via hostNetwork on port 53, rewrites `*.catinthehack.ca`, and blocks ads. The Helm chart seeds config from HelmRelease values; a SOPS-encrypted Secret stores the admin password.

**Tech Stack:** AdGuard Home v0.107.56 (gabe565 chart v0.3.25), Unbound 1.23.1 (pixelfederation chart v0.2.0), Flux v2.7, SOPS + age

---

## Prerequisites

- SOPS age key configured (`.sops.yaml` present, `.age-key.txt` exists)
- An admin password for AdGuard Home's web UI (bcrypt-hashed in Task 3)

---

### Task 0: Add Helm to Mise

**Files:**
- Modify: `.mise.toml`

**Step 1: Add helm to the tools section**

Add `helm` to the `[tools]` section in `.mise.toml`:

```toml
helm = "3.17"
```

**Step 2: Install**

Run: `mise install`

Expected: Helm 3.17.x installed.

**Step 3: Verify chart values**

Run these commands to inspect default values for both charts. Verify that HelmRelease values in later tasks match the chart's structure:

```bash
helm repo add gabe565 https://charts.gabe565.com
helm repo add unbound-helmchart https://pixelfederation.github.io/unbound
helm show values gabe565/adguard-home --version 0.3.25 > /tmp/adguard-values.yaml
helm show values unbound-helmchart/unbound --version 0.2.0 > /tmp/unbound-values.yaml
```

Inspect `/tmp/adguard-values.yaml` and `/tmp/unbound-values.yaml` to confirm the values structures match Tasks 2 and 3. Adjust HelmRelease values if the charts have changed since this plan.

**Step 4: Commit**

```bash
git add .mise.toml
git commit -m "chore: add helm to mise tool versions"
```

---

### Task 1: Scaffold adguard directory and namespace

**Files:**
- Create: `kubernetes/infrastructure/adguard/namespace.yaml`
- Create: `kubernetes/infrastructure/adguard/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create namespace.yaml**

```yaml
# kubernetes/infrastructure/adguard/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: adguard
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

AdGuard Home binds port 53 on the node IP via `hostNetwork: true`. TalosOS enforces `baseline` PSA by default, blocking hostNetwork without the `privileged` label.

**Step 2: Create kustomization.yaml**

```yaml
# kubernetes/infrastructure/adguard/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

Later tasks add `./unbound` and `./adguard-home` entries.

**Step 3: Wire into parent kustomization**

```yaml
# kubernetes/infrastructure/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway-api
  - cert-manager
  - traefik
  - nfs-provisioner
  - kyverno
  - adguard
```

**Step 4: Validate**

Run: `mise run check`

Expected: `kubernetes/infrastructure/` shows one additional valid resource (Namespace), 0 invalid.

**Step 5: Commit**

```bash
git add kubernetes/infrastructure/adguard/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(adguard): scaffold adguard namespace with privileged PSA"
```

---

### Task 2: Deploy Unbound

**Files:**
- Create: `kubernetes/infrastructure/adguard/unbound/helmrepository.yaml`
- Create: `kubernetes/infrastructure/adguard/unbound/helmrelease.yaml`
- Create: `kubernetes/infrastructure/adguard/unbound/kustomization.yaml`
- Modify: `kubernetes/infrastructure/adguard/kustomization.yaml`

**Step 1: Create helmrepository.yaml**

```yaml
# kubernetes/infrastructure/adguard/unbound/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: unbound
  namespace: adguard
spec:
  interval: 60m
  url: https://pixelfederation.github.io/unbound
```

**Step 2: Create helmrelease.yaml**

> **Review note — verify during implementation:** Run `helm show values unbound-helmchart/unbound --version 0.2.0` and confirm the values structure matches. Verify: `containers.unbound.config` path, `service` structure, `replicaCount` field name.

```yaml
# kubernetes/infrastructure/adguard/unbound/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: unbound
  namespace: adguard
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: unbound
      version: "0.2.0"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: unbound
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    replicaCount: 1
    containers:
      unbound:
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 128Mi
        config:
          verbosity: 1
          logReplies: "no"
          logQueries: "no"
          logTagQueryreply: "no"
          logLocalActions: "no"
          logServfail: "yes"
          numThreads: 1
          doTcp: "yes"
          doIp6: "no"
          prefetch: "yes"
          cacheMaxTtl: 86400
          cacheMaxNegativeTtl: 300
          tcpUpstream: "no"
          valPermissiveMode: "no"
          rootHints:
            enable: true
            dir: "/var/lib/unbound/root.hints"
          autoTrustAnchorFile:
            enable: true
            file: "/var/lib/unbound/root.key"
          allowedIpRanges:
            - "10.0.0.0/8"
            - "172.16.0.0/12"
            - "192.168.0.0/16"
      exporter:
        resources:
          requests:
            cpu: 2m
            memory: 10Mi
    metrics:
      enabled: false
    serviceMonitor:
      enabled: false
    service:
      type: ClusterIP
      tcp:
        enabled: true
      udp:
        enabled: true
```

Key values:
- `replicaCount: 1` — one replica suffices for a single-node cluster
- `cacheMaxTtl: 86400` — caches DNS responses up to 24 hours (default 3600 is conservative)
- `cacheMaxNegativeTtl: 300` — caches negative responses for 5 minutes
- `allowedIpRanges` — restricted to RFC1918 ranges, covering cluster CIDR and the node IP via hostNetwork
- `verbosity: 1` + logging disabled — minimal production logging; increase verbosity when debugging
- `metrics: false` — enable when Prometheus is deployed (roadmap step 8)

**Step 3: Create kustomization.yaml**

```yaml
# kubernetes/infrastructure/adguard/unbound/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrepository.yaml
  - helmrelease.yaml
```

**Step 4: Update parent adguard kustomization**

```yaml
# kubernetes/infrastructure/adguard/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - ./unbound
```

**Step 5: Validate**

Run: `mise run check`

Expected: `kubernetes/infrastructure/` shows additional valid resources (HelmRepository, HelmRelease for Unbound), 0 invalid.

**Step 6: Commit**

```bash
git add kubernetes/infrastructure/adguard/
git commit -m "feat(unbound): add Unbound recursive DNS resolver"
```

---

### Task 3: Deploy AdGuard Home

This task requires an admin password for AdGuard Home's web UI. Ask the user before proceeding.

**Files:**
- Create: `kubernetes/infrastructure/adguard/adguard-home/helmrepository.yaml`
- Create: `kubernetes/infrastructure/adguard/adguard-home/helmrelease.yaml`
- Create: `kubernetes/infrastructure/adguard/adguard-home/secret.enc.yaml`
- Create: `kubernetes/infrastructure/adguard/adguard-home/httproute.yaml`
- Create: `kubernetes/infrastructure/adguard/adguard-home/kustomization.yaml`
- Modify: `kubernetes/infrastructure/adguard/kustomization.yaml`

**Step 1: Create helmrepository.yaml**

```yaml
# kubernetes/infrastructure/adguard/adguard-home/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: gabe565
  namespace: adguard
spec:
  interval: 60m
  url: https://charts.gabe565.com
```

**Step 2: Create helmrelease.yaml**

> **Review note — verify during implementation:** Run `helm show values gabe565/adguard-home --version 0.3.25` and confirm the values structure matches. The gabe565 chart depends on bjw-s common library v1.5.1 — `hostNetwork` and `dnsPolicy` are root-level fields (not nested under `defaultPodOptions`, which was introduced in common v2.x). Verify: `service` names and port structure, `persistence` field names and mountPaths, `config` mapping to AdGuardHome.yaml.

```yaml
# kubernetes/infrastructure/adguard/adguard-home/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: adguard-home
  namespace: adguard
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: adguard-home
      version: "0.3.25"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: gabe565
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  valuesFrom:
    - kind: Secret
      name: adguard-home-values
      valuesKey: values.yaml
  values:
    hostNetwork: true
    dnsPolicy: ClusterFirstWithHostNet
    service:
      dns-tcp:
        enabled: true
        type: ClusterIP
        annotations: {}
        ports:
          dns-tcp:
            enabled: true
            port: 53
          dns-over-tls:
            enabled: false
      dns-udp:
        enabled: true
        type: ClusterIP
        annotations: {}
        ports:
          dns-udp:
            enabled: true
            protocol: UDP
            port: 53
          dns-over-quic:
            enabled: false
    persistence:
      config:
        enabled: true
        storageClass: nfs
        accessMode: ReadWriteOnce
        size: 1Gi
      data:
        enabled: true
        storageClass: nfs
        accessMode: ReadWriteOnce
        size: 2Gi
    config:
      dns:
        upstream_dns:
          - unbound.adguard.svc.cluster.local
        bootstrap_dns: []
        rewrites:
          - domain: "*.catinthehack.ca"
            answer: 192.168.20.100
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 256Mi
```

Key values:
- `hostNetwork: true` — binds port 53 on the node IP (`192.168.20.100`). Root-level field in bjw-s common library v1.5.1.
- `dnsPolicy: ClusterFirstWithHostNet` — hostNetwork pods default to the node's DNS, which cannot resolve cluster-internal names. This policy routes DNS through CoreDNS, so the pod resolves `unbound.adguard.svc.cluster.local`.
- `service.dns-*.type: ClusterIP` — overrides the chart's default LoadBalancer (no MetalLB in this cluster)
- `service.dns-*.annotations: {}` — clears the chart's default MetalLB annotations
- `persistence.*.storageClass: nfs` — stores data on the Synology NAS via the NFS provisioner
- `config.dns.upstream_dns` — forwards queries to Unbound's ClusterIP service for recursive resolution
- `config.dns.bootstrap_dns: []` — clears the chart's default Quad9 bootstrap DNS; unnecessary because CoreDNS resolves the upstream hostname
- `config.dns.rewrites` — resolves `*.catinthehack.ca` to the cluster IP
- `valuesFrom` — merges the admin password from the SOPS-encrypted Secret into `config.users` (Flux deep-merges values before Helm renders)

**Step 3: Generate the admin password hash and create the SOPS secret**

Ask the user for their admin password. Generate a bcrypt hash:

```bash
htpasswd -bnBC 10 "" 'THE_PASSWORD' | tr -d ':\n'
```

If `htpasswd` is unavailable:

```bash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'THE_PASSWORD', bcrypt.gensalt(10)).decode())"
```

Create the plaintext Secret file:

```yaml
# kubernetes/infrastructure/adguard/adguard-home/secret.enc.yaml
apiVersion: v1
kind: Secret
metadata:
  name: adguard-home-values
  namespace: adguard
stringData:
  values.yaml: |
    config:
      users:
        - name: admin
          password: "INSERT_BCRYPT_HASH_HERE"
```

Replace `INSERT_BCRYPT_HASH_HERE` with the bcrypt hash from the previous step. Keep the double quotes; `$` characters in bcrypt hashes require YAML quoting.

Then encrypt in-place:

```bash
sops encrypt -i kubernetes/infrastructure/adguard/adguard-home/secret.enc.yaml
```

Verify: `cat kubernetes/infrastructure/adguard/adguard-home/secret.enc.yaml` shows `ENC[AES256_GCM,...]` values and a `sops:` metadata block.

**Step 4: Create httproute.yaml**

```yaml
# kubernetes/infrastructure/adguard/adguard-home/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: adguard-home
  namespace: adguard
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "adguard.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: adguard-home
          port: 3000
```

Routes `adguard.catinthehack.ca` to the AdGuard Home web UI on port 3000, following the same cross-namespace Gateway pattern as the whoami app.

> **Review note — verify during implementation:** Confirm the chart's Service name. The gabe565 chart names the main service after the release, so `adguard-home` should be correct. After deployment, verify with `kubectl get svc -n adguard`.

**Step 5: Create kustomization.yaml**

```yaml
# kubernetes/infrastructure/adguard/adguard-home/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrepository.yaml
  - helmrelease.yaml
  - secret.enc.yaml
  - httproute.yaml
```

**Step 6: Update parent adguard kustomization**

```yaml
# kubernetes/infrastructure/adguard/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - ./unbound
  - ./adguard-home
```

**Step 7: Validate**

Run: `mise run check`

Expected: `kubernetes/infrastructure/` shows additional valid resources (HelmRepository, HelmRelease, Secret, HTTPRoute for AdGuard Home), 0 invalid.

**Step 8: Commit**

```bash
git add kubernetes/infrastructure/adguard/
git commit -m "feat(adguard): add AdGuard Home with DNS rewrite and Unbound upstream"
```

---

### Task 4: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Update CLAUDE.md**

Add to the Key Files table:

| File | Purpose |
|------|---------|
| `kubernetes/infrastructure/adguard/` | AdGuard Home DNS + Unbound recursive resolver |

Add to Implementation Notes:

- **AdGuard Home DNS**: Network DNS server with ad-blocking and DNS rewrite (`*.catinthehack.ca -> 192.168.20.100`). Uses `hostNetwork: true` to bind port 53 on the node IP and `dnsPolicy: ClusterFirstWithHostNet` to route the pod's DNS through CoreDNS instead of the node's resolver. The `adguard` namespace requires `privileged` PSA, same as `traefik`.
- **Unbound recursive resolver**: AdGuard Home's sole upstream. Queries root nameservers directly; no third-party forwarders. ClusterIP service only — not exposed outside the cluster. DNSSEC validation enabled.
- **AdGuard Home config seeding**: The gabe565 Helm chart generates a ConfigMap from the `config` values key and copies it to the config PVC on first boot only; subsequent restarts preserve UI changes. Flux injects the admin password (bcrypt hash) via `valuesFrom` from a SOPS-encrypted Secret, deep-merged into chart values before Helm renders the config.
- **DNS circular dependency avoidance**: AdGuard Home runs on `hostNetwork` with `ClusterFirstWithHostNet` DNS policy. The pod resolves `unbound.adguard.svc.cluster.local` via CoreDNS, which forwards non-cluster queries to TalosOS Host DNS. TalosOS Host DNS uses `machine.network.nameservers` (static, set in Terraform) rather than DHCP-acquired DNS — this breaks the loop when router DHCP points at AdGuard Home. **Prerequisite:** `machine.network.nameservers` must be set to external resolvers (e.g., `1.1.1.1`, `8.8.8.8`) before changing router DHCP, or a node restart will deadlock.

**Step 2: Update README.md roadmap**

Mark step 7 (Internal DNS) complete and the "Service domain" decision as decided:

- Step 7: ~~**Internal DNS** — Resolve friendly service names to the ingress IP~~
- Service domain row: ~~`*.home.arpa`, `*.cloudlab.local`, or a real domain with split-horizon DNS~~ → `*.catinthehack.ca` with AdGuard Home DNS rewrite (chosen)

**Step 3: Validate**

Run: `mise run check`

Expected: All checks pass (documentation changes do not affect validation results).

**Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: add AdGuard Home and Unbound implementation notes"
```

---

## Deployment Notes

After all tasks are committed and pushed:

1. **Flux reconciliation** — Flux detects the new manifests and applies them. Unbound starts first (no dependencies); AdGuard Home retries upstream connections until Unbound is ready. kustomize-controller decrypts the SOPS Secret and creates the Kubernetes Secret before helm-controller processes the HelmRelease.

2. **Verify Unbound** — Confirm Unbound runs and resolves:

   ```bash
   kubectl get pods -n adguard
   kubectl exec -n adguard deploy/unbound -- nslookup example.com 127.0.0.1
   ```

3. **Verify AdGuard Home DNS** — Query the DNS server from any network machine:

   ```bash
   dig whoami.catinthehack.ca @192.168.20.100
   dig example.com @192.168.20.100
   ```

   The first returns `192.168.20.100`. The second returns a real IP, resolved recursively via Unbound.

4. **Verify AdGuard Home web UI** — Visit `https://adguard.catinthehack.ca` and log in with the admin credentials.

5. **TalosOS static nameservers** — Before changing router DHCP, verify that `machine.network.nameservers` is set in the Talos machine config (e.g., `["1.1.1.1", "8.8.8.8"]`). Without static nameservers, the node acquires DNS from DHCP. After the router points DHCP DNS at `192.168.20.100`, a node restart deadlocks: the node cannot resolve DNS to pull images, the cluster cannot start, and AdGuard cannot start. Static nameservers ensure TalosOS always has a working upstream DNS independent of the in-cluster DNS server.

6. **Router DHCP** — Set primary DNS to `192.168.20.100`, secondary to `1.1.1.1`. Devices pick up the change at their next DHCP renewal (or immediately via `ipconfig /release && ipconfig /renew` on Windows, `sudo dhclient -r && sudo dhclient` on Linux).

7. **Troubleshooting** — If DNS resolution fails:

   ```bash
   kubectl logs -n adguard deploy/adguard-home     # Check AdGuard Home logs
   kubectl logs -n adguard deploy/unbound           # Check Unbound logs
   kubectl get helmrelease -n adguard               # Check Flux reconciliation status
   kubectl get pvc -n adguard                       # Verify PVCs are bound
   ```

   If AdGuard Home cannot reach Unbound, verify the pod's `dnsPolicy` is `ClusterFirstWithHostNet`:

   ```bash
   kubectl get pod -n adguard -l app.kubernetes.io/name=adguard-home -o jsonpath='{.items[0].spec.dnsPolicy}'
   ```
