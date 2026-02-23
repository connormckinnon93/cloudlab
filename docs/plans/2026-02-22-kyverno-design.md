# Kyverno Image Verification

Deploy Kyverno as a policy engine with image signature verification in audit mode, scoped to GHCR images signed via GitHub Actions.

## Scope

- Deploy Kyverno via Flux HelmRelease
- Create a ClusterPolicy that verifies GHCR container images (Flux, Kyverno) against Sigstore's keyless signing infrastructure
- Run in audit mode: log violations, admit unverified images
- Update the roadmap: remove etcd backups (step 12), add future Kyverno hardening items

## Architecture

### Deployment

Kyverno installs as four controllers (admission, background, cleanup, reports), each in its own Deployment. All run with a single replica on this single-node cluster.

Directory structure follows the established infrastructure pattern:

```
kubernetes/infrastructure/kyverno/
  namespace.yaml                          # kyverno namespace
  helmrepository.yaml                     # https://kyverno.github.io/kyverno/
  helmrelease.yaml                        # kyverno chart with resource limits
  clusterpolicy-verify-images.yaml        # GHCR image verification policy
  kustomization.yaml                      # lists above resources
```

The parent `kubernetes/infrastructure/kustomization.yaml` adds `kyverno` to its resource list.

### Image Verification Policy

A single `ClusterPolicy` verifies GHCR images (Flux and Kyverno controllers) against Sigstore's public-good infrastructure. System namespaces are excluded to avoid circular dependency risks:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  webhookConfiguration:
    timeoutSeconds: 30
  rules:
    - name: verify-sigstore-keyless
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      verifyImages:
        - imageReferences:
            - "ghcr.io/fluxcd/*"
            - "ghcr.io/kyverno/*"
          failureAction: Audit
          attestors:
            - entries:
                - keyless:
                    issuerRegExp: "https://token\\.actions\\.githubusercontent\\..*"
                    subjectRegExp: "https://github\\.com/.+"
                    rekor:
                      url: https://rekor.sigstore.dev
```

Scoping `imageReferences` to `ghcr.io/fluxcd/*` and `ghcr.io/kyverno/*` targets images actually signed via GitHub Actions keyless. This keeps PolicyReport results meaningful -- violations indicate genuine signing failures rather than expected mismatches for images using other signing methods. System namespaces (`kube-system`, `kyverno`) are excluded to prevent circular dependency risks during bootstrapping.

Migrating to enforce mode requires narrowing scope further or adding attestor entries for other signing authorities before flipping the `failureAction`.

Inspect violations:

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport -o yaml
```

### Helm Values

Resource limits keep Kyverno bounded on this single-node cluster:

```yaml
admissionController:
  replicas: 1
  container:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        memory: 384Mi
backgroundController:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 256Mi
cleanupController:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi
reportsController:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 256Mi
```

### Roadmap Changes

Remove step 12 (etcd backups). With GitOps managing cluster state and application data on NFS PVCs, the cluster is fully reconstructable without etcd snapshots. Proxmox VM-level backups cover disaster recovery.

Add two future items to Phase 3 (Expand and Harden), alongside network policies:

- **Kyverno enforce mode** -- migrate image verification from audit to enforce
- **Kyverno general policies** -- disallow privileged containers, require resource limits, disallow `latest` tag

## Validation

1. Flux reconciles the Kyverno HelmRelease and all four controllers reach Ready
2. The ClusterPolicy is created and reports `Ready: true`
3. PolicyReports exist and show audit results for existing workloads
4. `mise run check` passes (kustomize build + kubeconform)
5. No existing workloads are disrupted (audit mode admits everything)
