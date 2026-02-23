# Ingress and TLS Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Route HTTPS traffic through Traefik to cluster services, secured by a Let's Encrypt wildcard certificate for `*.catinthehack.ca`.

**Architecture:** Three infrastructure components deployed via Flux: Gateway API CRDs (standard Kubernetes routing API), cert-manager (DNS-01 via DigitalOcean for wildcard cert), and Traefik (Gateway API provider with hostPort 80/443). HTTP redirects to HTTPS. Flux retries handle inter-component dependency ordering.

**Tech Stack:** Gateway API v1.4.1, cert-manager v1.19.3, Traefik v3.6.6 (Helm chart v38.0.2), SOPS + age encryption, Flux v2.7

---

## Prerequisites

- DigitalOcean API token — create a **custom-scoped** token with DNS read/write permissions only (not a full-access token). Create at DigitalOcean dashboard → API → Personal access tokens.
- Email address for Let's Encrypt registration
- SOPS age key configured (`.sops.yaml` already present)

> **Note:** Consider testing with Let's Encrypt staging (`https://acme-staging-v02.api.letsencrypt.org/directory`) first to avoid rate limits during initial setup. The ClusterIssuer server URL can be switched to production after confirming the DNS-01 flow works.

---

### Task 1: Gateway API CRDs

**Files:**
- Create: `kubernetes/infrastructure/gateway-api/kustomization.yaml`
- Download: `kubernetes/infrastructure/gateway-api/standard-install.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create directory and download CRD bundle**

```bash
mkdir -p kubernetes/infrastructure/gateway-api
curl -sL https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml \
  -o kubernetes/infrastructure/gateway-api/standard-install.yaml
```

Verify: file should be ~696 KB and contain `kind: CustomResourceDefinition`.

**Step 2: Create kustomization.yaml**

```yaml
# kubernetes/infrastructure/gateway-api/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - standard-install.yaml
```

**Step 3: Wire into parent kustomization**

```yaml
# kubernetes/infrastructure/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway-api
  - nfs-provisioner
```

`gateway-api` listed first — CRDs should be applied before components that use them.

**Step 4: Validate**

Run: `mise run check`

Expected: `kubernetes/infrastructure/` shows additional valid CRD resources, 0 invalid.

**Step 5: Commit**

```bash
git add kubernetes/infrastructure/gateway-api/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(gateway-api): vendor Gateway API CRDs v1.4.1"
```

---

### Task 2: cert-manager core

**Files:**
- Create: `kubernetes/infrastructure/cert-manager/namespace.yaml`
- Create: `kubernetes/infrastructure/cert-manager/helmrepository.yaml`
- Create: `kubernetes/infrastructure/cert-manager/helmrelease.yaml`
- Create: `kubernetes/infrastructure/cert-manager/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create namespace.yaml**

```yaml
# kubernetes/infrastructure/cert-manager/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
```

**Step 2: Create helmrepository.yaml**

```yaml
# kubernetes/infrastructure/cert-manager/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  interval: 60m
  url: https://charts.jetstack.io
```

**Step 3: Create helmrelease.yaml**

```yaml
# kubernetes/infrastructure/cert-manager/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: cert-manager
      version: "v1.19.3"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: cert-manager
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
    crds:
      enabled: true
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 256Mi
```

`crds.enabled: true` tells the chart to include CRDs in its templates. `install.crds: CreateReplace` tells Flux to create or update CRDs during install and upgrade.

**Step 4: Create kustomization.yaml**

```yaml
# kubernetes/infrastructure/cert-manager/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
```

**Step 5: Wire into parent kustomization**

```yaml
# kubernetes/infrastructure/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway-api
  - cert-manager
  - nfs-provisioner
```

**Step 6: Validate**

Run: `mise run check`

Expected: `kubernetes/infrastructure/` shows additional valid resources (Namespace, HelmRepository, HelmRelease for cert-manager), 0 invalid.

**Step 7: Commit**

```bash
git add kubernetes/infrastructure/cert-manager/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(cert-manager): add cert-manager HelmRelease v1.19.3"
```

---

### Task 3: cert-manager configuration

This task requires user input: a DigitalOcean API token and an email address for Let's Encrypt. Ask the user before proceeding.

**Files:**
- Modify: `.mise.toml` (update check task for SOPS compatibility)
- Create: `kubernetes/infrastructure/cert-manager/secret.enc.yaml`
- Create: `kubernetes/infrastructure/cert-manager/clusterissuer.yaml`
- Modify: `kubernetes/infrastructure/cert-manager/kustomization.yaml`

**Step 1: Update the check task to strip SOPS metadata**

`kubeconform -strict` rejects the extra `sops:` top-level key in encrypted YAML. Add an `awk` filter to strip SOPS metadata before validation.

In `.mise.toml`, in the `[tasks.check]` run block, change this line:

```
      kustomize build "$dir" | kubeconform -strict -summary -ignore-missing-schemas \
```

To:

```
      kustomize build "$dir" | awk '/^sops:/{s=1;next} s&&/^[^[:space:]]/{s=0} !s' | kubeconform -strict -summary -ignore-missing-schemas \
```

This strips `sops:` and its indented children from the YAML stream. Safe because `sops` is never a legitimate top-level key in Kubernetes resources. `kustomize build` outputs encrypted values as-is (Flux decrypts at reconciliation time, not locally).

**Step 2: Create secret.enc.yaml**

Create the Secret with the user's DigitalOcean API token:

```yaml
# kubernetes/infrastructure/cert-manager/secret.enc.yaml
apiVersion: v1
kind: Secret
metadata:
  name: digitalocean-dns
  namespace: cert-manager
type: Opaque
stringData:
  access-token: "INSERT_DIGITALOCEAN_API_TOKEN"
```

Then encrypt in-place:

```bash
sops encrypt -i kubernetes/infrastructure/cert-manager/secret.enc.yaml
```

Verify: `cat kubernetes/infrastructure/cert-manager/secret.enc.yaml` shows `ENC[AES256_GCM,...]` values and `sops:` metadata block.

**Step 3: Create clusterissuer.yaml**

Use the email address provided by the user:

```yaml
# kubernetes/infrastructure/cert-manager/clusterissuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: INSERT_EMAIL_ADDRESS
    privateKeySecretRef:
      name: letsencrypt-production
    solvers:
      - dns01:
          digitalocean:
            tokenSecretRef:
              name: digitalocean-dns
              key: access-token
```

The ClusterIssuer is cluster-scoped. cert-manager looks for `tokenSecretRef` in the cert-manager namespace (where cert-manager runs).

**Step 4: Update kustomization.yaml**

```yaml
# kubernetes/infrastructure/cert-manager/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
  - secret.enc.yaml
  - clusterissuer.yaml
```

**Step 5: Validate**

Run: `mise run check`

Expected: All checks pass. The encrypted Secret passes validation after SOPS metadata stripping. ClusterIssuer is skipped (missing schema) or validated via CRDs catalog.

**Step 6: Commit**

```bash
git add .mise.toml \
  kubernetes/infrastructure/cert-manager/secret.enc.yaml \
  kubernetes/infrastructure/cert-manager/clusterissuer.yaml \
  kubernetes/infrastructure/cert-manager/kustomization.yaml
git commit -m "feat(cert-manager): add ClusterIssuer and DO API token for DNS-01"
```

---

### Task 4: Traefik core with Gateway

**Files:**
- Create: `kubernetes/infrastructure/traefik/namespace.yaml`
- Create: `kubernetes/infrastructure/traefik/helmrepository.yaml`
- Create: `kubernetes/infrastructure/traefik/helmrelease.yaml`
- Create: `kubernetes/infrastructure/traefik/kustomization.yaml`
- Modify: `kubernetes/infrastructure/kustomization.yaml`

**Step 1: Create namespace.yaml**

TalosOS enforces `baseline` Pod Security Admission by default. hostPort bindings are blocked under `baseline`. The `privileged` label exempts this namespace.

```yaml
# kubernetes/infrastructure/traefik/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

**Step 2: Create helmrepository.yaml**

```yaml
# kubernetes/infrastructure/traefik/helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: traefik
  namespace: traefik
spec:
  interval: 60m
  url: https://traefik.github.io/charts
```

**Step 3: Create helmrelease.yaml**

```yaml
# kubernetes/infrastructure/traefik/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: traefik
spec:
  interval: 30m
  timeout: 5m
  dependsOn:
    - name: cert-manager
      namespace: cert-manager
  chart:
    spec:
      chart: traefik
      version: "38.0.2"
      interval: 60m
      sourceRef:
        kind: HelmRepository
        name: traefik
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
    providers:
      kubernetesIngress:
        enabled: false
      kubernetesGateway:
        enabled: true
    gateway:
      enabled: true
      name: traefik-gateway
      listeners:
        websecure:
          port: 8443
          protocol: HTTPS
          hostname: "*.catinthehack.ca"
          certificateRefs:
            - name: wildcard-catinthehack-ca-tls
          namespacePolicy:
            from: All
    ingressRoute:
      dashboard:
        enabled: false
    api:
      dashboard: true
      insecure: true
    ports:
      web:
        port: 8000
        hostPort: 80
        redirections:
          entryPoint:
            to: websecure
            scheme: https
            permanent: true
      websecure:
        port: 8443
        hostPort: 443
    service:
      type: ClusterIP
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 256Mi
```

Key values:
- `providers.kubernetesIngress.enabled: false` — all-in on Gateway API, no Ingress resources
- `providers.kubernetesGateway.enabled: true` — Traefik watches Gateway/HTTPRoute resources
- `gateway.enabled: true` — chart creates a Gateway and GatewayClass
- `gateway.name: traefik-gateway` — explicit name avoids ambiguity (chart default may vary by version)
- `gateway.listeners.websecure.hostname: "*.catinthehack.ca"` — wildcard listener
- `gateway.listeners.websecure.certificateRefs` — references the TLS Secret created by cert-manager
- `gateway.listeners.websecure.namespacePolicy.from: All` — HTTPRoutes from any namespace can attach
- `ingressRoute.dashboard.enabled: false` — we expose the dashboard via HTTPRoute instead
- `api.insecure: true` — dashboard accessible on internal API port (secure with SSO in step 13)
- `ports.web.hostPort: 80` / `ports.websecure.hostPort: 443` — bind directly to node
- `ports.web.redirections` — HTTP→HTTPS permanent redirect at the entrypoint level
- `service.type: ClusterIP` — no LoadBalancer needed with hostPort
- `dependsOn` — waits for cert-manager HelmRelease to be Ready before installing Traefik

> **Review note — verify during implementation:** Three Helm chart values had conflicting reviewer findings. Before writing `helmrelease.yaml`, run `helm show values traefik/traefik --version 38.0.2` and verify:
>
> 1. **Redirect syntax** — Plan uses `ports.web.redirections.entryPoint.to: websecure`. Alternate form: `ports.web.redirectTo.port: websecure`. Check which key the chart actually supports.
> 2. **Dashboard API port** — Plan uses port 9000. Alternate: port 8080. Check `ports.traefik.port` in default values.
> 3. **Gateway default name** — Plan sets `gateway.name: traefik-gateway` explicitly. Confirm the chart accepts this key and what the default would be without it.

**Step 4: Create kustomization.yaml**

```yaml
# kubernetes/infrastructure/traefik/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
```

**Step 5: Wire into parent kustomization**

```yaml
# kubernetes/infrastructure/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway-api
  - cert-manager
  - traefik
  - nfs-provisioner
```

**Step 6: Validate**

Run: `mise run check`

Expected: `kubernetes/infrastructure/` shows additional valid resources for traefik, 0 invalid.

**Step 7: Commit**

```bash
git add kubernetes/infrastructure/traefik/ kubernetes/infrastructure/kustomization.yaml
git commit -m "feat(traefik): add Traefik HelmRelease v38.0.2 with Gateway API"
```

---

### Task 5: Wildcard Certificate

**Files:**
- Create: `kubernetes/infrastructure/traefik/certificate.yaml`
- Modify: `kubernetes/infrastructure/traefik/kustomization.yaml`

**Step 1: Create certificate.yaml**

```yaml
# kubernetes/infrastructure/traefik/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-catinthehack-ca
  namespace: traefik
spec:
  secretName: wildcard-catinthehack-ca-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - "*.catinthehack.ca"
    - "catinthehack.ca"
```

The Certificate lives in the `traefik` namespace so the resulting TLS Secret (`wildcard-catinthehack-ca-tls`) is created there — directly accessible by the Gateway listener.

**Step 2: Update kustomization.yaml**

```yaml
# kubernetes/infrastructure/traefik/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
  - certificate.yaml
```

**Step 3: Validate**

Run: `mise run check`

Expected: One additional resource in `traefik/` (Certificate — skipped if schema not in catalog, or valid). All checks pass.

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/traefik/certificate.yaml \
  kubernetes/infrastructure/traefik/kustomization.yaml
git commit -m "feat(tls): add wildcard Certificate for *.catinthehack.ca"
```

---

### Task 6: Dashboard HTTPRoute

**Files:**
- Create: `kubernetes/infrastructure/traefik/httproute-dashboard.yaml`
- Modify: `kubernetes/infrastructure/traefik/kustomization.yaml`

**Step 1: Create httproute-dashboard.yaml**

```yaml
# kubernetes/infrastructure/traefik/httproute-dashboard.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: traefik-dashboard
  namespace: traefik
spec:
  parentRefs:
    - name: traefik-gateway
  hostnames:
    - "traefik.catinthehack.ca"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: traefik
          port: 9000
```

Routes `traefik.catinthehack.ca` to the Traefik API/dashboard service. The Gateway name `traefik-gateway` is set explicitly in the HelmRelease values.

> **Review note — verify during implementation:** The dashboard backendRef port (9000 above) and Gateway name should match the actual chart defaults. Run `helm show values traefik/traefik --version 38.0.2` and check `ports.traefik.port` and `gateway.name` before writing this file. After deployment, confirm with: `kubectl get svc -n traefik traefik -o yaml`.

**Step 2: Update kustomization.yaml**

```yaml
# kubernetes/infrastructure/traefik/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
  - certificate.yaml
  - httproute-dashboard.yaml
```

**Step 3: Validate**

Run: `mise run check`

Expected: One additional resource in `traefik/` (HTTPRoute — skipped or valid). All checks pass.

**Step 4: Commit**

```bash
git add kubernetes/infrastructure/traefik/httproute-dashboard.yaml \
  kubernetes/infrastructure/traefik/kustomization.yaml
git commit -m "feat(traefik): add HTTPRoute for dashboard smoke test"
```

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Update CLAUDE.md**

Add to the Key Files table:

| File | Purpose |
|------|---------|
| `kubernetes/infrastructure/gateway-api/` | Gateway API CRDs (v1.4.1, vendored) |
| `kubernetes/infrastructure/cert-manager/` | cert-manager with DNS-01 via DigitalOcean |
| `kubernetes/infrastructure/traefik/` | Traefik ingress with Gateway API, wildcard TLS |

Add to Implementation Notes:

- **Gateway API CRDs**: Vendored from `kubernetes-sigs/gateway-api` v1.4.1 (`standard-install.yaml`). Installed as raw YAML before components that create Gateway or HTTPRoute resources. Flux's kustomize-controller discourages remote HTTP URLs for source provenance, so the file is committed to the repo.
- **cert-manager DNS-01**: DigitalOcean DNS provider for Let's Encrypt challenges. The SOPS-encrypted API token (`secret.enc.yaml`) lives in the cert-manager directory. The ClusterIssuer is cluster-scoped; cert-manager looks for the token Secret in the cert-manager namespace.
- **Traefik Gateway API**: Gateway and GatewayClass created by the Helm chart (`gateway.enabled: true`). Default Gateway name is `traefik-gateway`. HTTPRoutes from any namespace can attach (`namespacePolicy.from: All`). Dashboard exposed via HTTPRoute — secure with SSO in step 13.
- **hostPort binding**: Traefik binds to node ports 80 and 443 via hostPort (mapped from container ports 8000 and 8443). No LoadBalancer or MetalLB needed. HTTP→HTTPS redirect at the entrypoint level, before Gateway routing.
- **Wildcard certificate**: The Certificate resource lives in the traefik namespace so the TLS Secret is co-located with the Gateway that references it. cert-manager renews automatically 30 days before expiry.
- **SOPS in kubernetes/**: The `mise run check` task strips `sops:` metadata from kustomize output before kubeconform validation (awk filter). Flux's kustomize-controller decrypts SOPS files at reconciliation time.
- **Flux retry ordering**: On first deployment, cert-manager CRDs may not exist when kustomize-controller applies ClusterIssuer and Certificate resources. Flux retries (`retryInterval: 2m`) succeed after helm-controller installs cert-manager. This is expected Flux behavior, not an error.

**Step 2: Update README.md roadmap**

- Mark steps 6 (Ingress controller) and 7 (cert-manager) as complete (`~~strikethrough~~`)
- Remove step 25 (Gateway API migration) — adopted from day one
- Add Velero to Phase 4: "**PersistentVolume and cluster backups** — Velero for scheduled backup and restore of all cluster resources"
- Mark Ingress approach as decided in the Key Decisions table: Traefik + Gateway API

**Step 3: Validate**

Run: `mise run check`

Expected: All checks pass (documentation changes do not affect validation).

**Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update CLAUDE.md and README.md for ingress and TLS"
```

---

## Deployment Notes

After all tasks are committed and pushed to `main`:

1. **Flux reconciliation** — Flux detects new manifests and applies them. First reconciliation may partially fail (cert-manager CRDs not yet installed for ClusterIssuer/Certificate). Second reconciliation (~2 minutes later) succeeds after helm-controller installs cert-manager.

2. **Certificate issuance** — cert-manager creates a DNS-01 TXT record on DigitalOcean, Let's Encrypt verifies it, and the wildcard cert is issued. Verify:

   ```bash
   kubectl get certificate -n traefik
   kubectl describe certificaterequest -n traefik
   ```

3. **Smoke test** — Add to `/etc/hosts` on your machine:

   ```
   192.168.20.100  traefik.catinthehack.ca
   ```

   Then verify:

   ```bash
   curl -v https://traefik.catinthehack.ca    # Valid TLS cert, Traefik dashboard
   curl -v http://traefik.catinthehack.ca     # 301 redirect to HTTPS
   ```

4. **Troubleshooting** — If the certificate is not issued:

   ```bash
   kubectl get challenges -n traefik             # DNS-01 challenge status
   kubectl describe order -n traefik             # Certificate order details
   kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
   ```
