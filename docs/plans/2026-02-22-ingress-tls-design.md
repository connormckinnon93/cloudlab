# Ingress and TLS — Design

## Goal

Route HTTP/HTTPS traffic to cluster services through Traefik, secured by a wildcard TLS certificate for `*.catinthehack.ca` issued automatically by cert-manager via Let's Encrypt.

This design covers roadmap steps 6 (ingress controller) and 7 (cert-manager), and eliminates step 25 (Gateway API migration) by adopting Gateway API from day one. It also adds Velero to the roadmap as a future backup strategy.

## Approach

Three infrastructure components, deployed in order:

1. **Gateway API CRDs** — the standard Kubernetes routing API, installed as standalone CRDs from the official release
2. **cert-manager** — automated TLS certificate provisioning via Let's Encrypt DNS-01 challenges against DigitalOcean DNS
3. **Traefik** — Gateway API-native ingress controller on hostPort 80/443, with HTTP-to-HTTPS redirect

### Why Traefik over Cilium ingress or ingress-nginx

Traefik provides first-class ForwardAuth middleware, which simplifies the SSO gateway planned in step 13 (Authelia or Authentik). Cilium's Gateway API support would avoid a separate component, but its auth integration requires more manual wiring. ingress-nginx lacks native Gateway API support.

Traefik also supports Gateway API natively, so the cluster starts with the standard routing API. This eliminates the step 25 migration entirely.

### Why DNS-01 over HTTP-01

DNS-01 challenges do not require the cluster to be reachable from the internet. cert-manager creates a TXT record on DigitalOcean DNS, Let's Encrypt verifies it, and the record is cleaned up. This is the only method that supports wildcard certificates.

The domain `catinthehack.ca` already uses DigitalOcean nameservers.

### Certificate persistence

cert-manager stores the wildcard TLS certificate as a Kubernetes Secret in etcd. This persists across pod restarts and node reboots. If the cluster is rebuilt from scratch, cert-manager re-requests the certificate — Let's Encrypt rate limits (50 certificates per domain per week) pose no concern for a single wildcard cert.

For broader disaster recovery, Velero (added to the roadmap) will back up and restore all cluster resources, including Secrets. That work belongs in a later step.

## Kubernetes Deployment

### File Structure

```
kubernetes/infrastructure/
├── kustomization.yaml              # Add gateway-api, cert-manager, traefik
├── gateway-api/
│   └── kustomization.yaml          # Remote resource: official CRD bundle
├── cert-manager/
│   ├── namespace.yaml              # Dedicated namespace
│   ├── helmrepository.yaml         # Jetstack Helm repo
│   ├── helmrelease.yaml            # cert-manager chart with CRDs
│   ├── secret.enc.yaml             # SOPS-encrypted DigitalOcean API token
│   ├── clusterissuer.yaml          # Let's Encrypt production + DNS-01
│   ├── certificate.yaml            # Wildcard cert for *.catinthehack.ca
│   └── kustomization.yaml          # Kustomize entry point
└── traefik/
    ├── namespace.yaml              # Dedicated namespace
    ├── helmrepository.yaml         # Traefik Helm repo
    ├── helmrelease.yaml            # Traefik chart with Gateway API config
    ├── gateway.yaml                # Gateway resource: HTTPS listener
    ├── httproute-dashboard.yaml    # Smoke test: Traefik dashboard route
    └── kustomization.yaml          # Kustomize entry point
```

### Dependency Chain

Flux Kustomizations enforce deployment order through `dependsOn`:

1. **gateway-api** — CRDs must exist before any Gateway or HTTPRoute resources
2. **cert-manager** (depends on gateway-api) — must issue the wildcard certificate before Traefik can reference it
3. **traefik** (depends on cert-manager) — references the wildcard cert Secret

Each component's Flux Kustomization lives in `kubernetes/flux-system/` alongside the existing `infrastructure.yaml`, or as `dependsOn` entries within the infrastructure Kustomization. The parent `kubernetes/infrastructure/kustomization.yaml` adds all three directories next to `nfs-provisioner`.

### Gateway API CRDs

The `gateway-api/kustomization.yaml` references the upstream CRD bundle as a remote Kustomize resource from the `kubernetes-sigs/gateway-api` GitHub release, pinned to a specific version tag (e.g., `standard-install.yaml` from v1.2.1). No Helm chart, no namespace — just cluster-scoped CRDs.

This keeps the CRDs independent of Traefik. Other controllers (Cilium, future experiments) can use them without changes.

### cert-manager

**Helm chart:** Jetstack's `cert-manager` chart, pinned version, with `crds.enabled: true` so the chart manages its own CRDs (separate from Gateway API CRDs).

**ClusterIssuer:** Configured for Let's Encrypt production with a DNS-01 solver. The solver uses the `digitalocean` provider and references a Secret containing the API token.

**Certificate:** A single wildcard Certificate for `*.catinthehack.ca`. The resulting TLS Secret is created in the `traefik` namespace so Traefik can reference it directly — cert-manager supports cross-namespace certificate creation natively.

**DigitalOcean API token:** Stored as a SOPS-encrypted Secret (`secret.enc.yaml`) in the cert-manager namespace. The token needs only DNS read/write scope. Created via `sops encrypt` following the existing `\.enc\.(json|yaml)$` pattern.

### Traefik

**Helm chart:** Traefik Labs' chart, pinned version, configured with:

- **Gateway API provider** enabled — Traefik watches Gateway and HTTPRoute resources
- **hostPort** on 80 and 443 — traffic to `192.168.20.100:80` and `:443` routes directly to Traefik pods, no LoadBalancer or MetalLB needed
- **HTTP-to-HTTPS redirect** — the port 80 entrypoint permanently redirects all requests to port 443
- **Dashboard enabled** — accessible through an HTTPRoute for validation

**Gateway resource:** Defines an HTTPS listener for `*.catinthehack.ca` on port 443, referencing the wildcard cert Secret. Also defines an HTTP listener on port 80 for the redirect.

**GatewayClass:** Created automatically by the Traefik Helm chart, or defined explicitly if the chart requires it.

### Smoke Test: Traefik Dashboard

An HTTPRoute (`httproute-dashboard.yaml`) routes `traefik.catinthehack.ca` to the Traefik dashboard service. Combined with an `/etc/hosts` entry on the developer machine:

```
192.168.20.100  traefik.catinthehack.ca
```

This proves the full chain: local DNS resolution, hostPort routing, TLS termination with a valid Let's Encrypt wildcard certificate, and Gateway API routing to a backend service.

## Prerequisites

1. **DigitalOcean API token** — create a scoped token with DNS read/write permissions. Encrypt it with SOPS and commit as `secret.enc.yaml`.
2. **`/etc/hosts` entry** — add `192.168.20.100 traefik.catinthehack.ca` to the developer machine for validation. Real DNS resolution (step 8) comes later.

## Roadmap Updates

- **Step 25 (Gateway API migration)** — eliminated; Gateway API adopted from the start
- **Velero (new)** — add to Phase 4 as a cluster-wide backup and restore solution, covering Secrets, PVCs, and all Kubernetes resources

## Validation

1. **Flux reconciliation** — all three Kustomizations reconcile without errors. `mise run check` passes.
2. **Gateway API CRDs** — `kubectl get crd gateways.gateway.networking.k8s.io` confirms CRDs are installed.
3. **Certificate issuance** — `kubectl get certificate -n traefik` shows the wildcard cert as `Ready`. `kubectl describe certificaterequest` confirms the DNS-01 challenge succeeded.
4. **Traefik pods** — `kubectl get pods -n traefik` shows Traefik running with hostPort bindings.
5. **End-to-end TLS** — `curl -v https://traefik.catinthehack.ca` (with `/etc/hosts` entry) returns the dashboard and shows a valid Let's Encrypt certificate for `*.catinthehack.ca`.
6. **HTTP redirect** — `curl -v http://traefik.catinthehack.ca` returns a 301 redirect to HTTPS.
