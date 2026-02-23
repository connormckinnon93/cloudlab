#!/usr/bin/env bash
set -euo pipefail

# Documentation accuracy test
# Verifies that file and directory paths referenced in CLAUDE.md, ARCHITECTURE.md,
# and README.md actually exist in the repository.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

check_path() {
    local source="$1"
    local path="$2"
    if [ -e "$path" ]; then
        echo "  PASS  $path"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $path  (referenced in $source)"
        FAIL=$((FAIL + 1))
    fi
}

# --------------------------------------------------------------------------
# CLAUDE.md — Repository Structure section
# --------------------------------------------------------------------------
echo "=== CLAUDE.md: Repository Structure ==="

check_path "CLAUDE.md" "terraform/"
check_path "CLAUDE.md" "terraform/output/"
check_path "CLAUDE.md" "docs/plans/"
check_path "CLAUDE.md" "kubernetes/"
check_path "CLAUDE.md" ".github/workflows/"

# --------------------------------------------------------------------------
# CLAUDE.md — Key Files table
# --------------------------------------------------------------------------
echo ""
echo "=== CLAUDE.md: Key Files ==="

check_path "CLAUDE.md" ".mise.toml"
check_path "CLAUDE.md" ".sops.yaml"
check_path "CLAUDE.md" "terraform/versions.tf"
check_path "CLAUDE.md" "terraform/variables.tf"
check_path "CLAUDE.md" "terraform/config.auto.tfvars"
check_path "CLAUDE.md" "terraform/main.tf"
check_path "CLAUDE.md" "terraform/talos.tf"
check_path "CLAUDE.md" "terraform/outputs.tf"
check_path "CLAUDE.md" "terraform/secrets.enc.json"
check_path "CLAUDE.md" "terraform/.tflint.hcl"
check_path "CLAUDE.md" "lefthook.yml"
check_path "CLAUDE.md" ".github/workflows/check.yml"
check_path "CLAUDE.md" "kubernetes/kustomization.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/"
check_path "CLAUDE.md" "kubernetes/flux-system/infrastructure.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/infrastructure-config.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure-config/"
check_path "CLAUDE.md" "kubernetes/flux-system/apps.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/cluster-policies.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure/kustomization.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure/nfs-provisioner/"
check_path "CLAUDE.md" "kubernetes/infrastructure/kyverno/"
check_path "CLAUDE.md" "kubernetes/cluster-policies/"
check_path "CLAUDE.md" "kubernetes/apps/kustomization.yaml"
check_path "CLAUDE.md" "kubernetes/apps/whoami/"
check_path "CLAUDE.md" "kubernetes/infrastructure/gateway-api/"
check_path "CLAUDE.md" "kubernetes/infrastructure/cert-manager/"
check_path "CLAUDE.md" "kubernetes/infrastructure/traefik/"
check_path "CLAUDE.md" "kubernetes/infrastructure/adguard/"
check_path "CLAUDE.md" "kubernetes/infrastructure/monitoring/"
check_path "CLAUDE.md" "kubernetes/infrastructure/cloudnative-pg/"
check_path "CLAUDE.md" "kubernetes/infrastructure/postgres/"
check_path "CLAUDE.md" "kubernetes/infrastructure/authentik/"
check_path "CLAUDE.md" "kubernetes/cluster-policies/clusterpolicy-inject-forward-auth.yaml"

# --------------------------------------------------------------------------
# CLAUDE.md — Implementation Notes (specific file references)
# --------------------------------------------------------------------------
echo ""
echo "=== CLAUDE.md: Implementation Notes ==="

# "pinned to a commit SHA in kubernetes/infrastructure/gateway-api/gitrepository.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure/gateway-api/gitrepository.yaml"

# "infrastructure-config/traefik-certificate.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure-config/traefik-certificate.yaml"

# "cert-manager-clusterissuer.yaml, monitoring-httproute-grafana.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure-config/cert-manager-clusterissuer.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure-config/monitoring-httproute-grafana.yaml"

# "grafana-datasource-loki.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure/monitoring/grafana-datasource-loki.yaml"

# "mise run sops:edit kubernetes/infrastructure/monitoring/secret.enc.yaml"
check_path "CLAUDE.md" "kubernetes/infrastructure/monitoring/secret.enc.yaml"

# "flux-system/kustomization.yaml manual additions" — references provider-alertmanager.yaml, alert-flux.yaml
check_path "CLAUDE.md" "kubernetes/flux-system/kustomization.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/provider-alertmanager.yaml"
check_path "CLAUDE.md" "kubernetes/flux-system/alert-flux.yaml"

# --------------------------------------------------------------------------
# CLAUDE.md — cross-reference docs
# --------------------------------------------------------------------------
echo ""
echo "=== CLAUDE.md: Cross-references ==="

check_path "CLAUDE.md" "ARCHITECTURE.md"

# --------------------------------------------------------------------------
# ARCHITECTURE.md — cross-reference docs
# --------------------------------------------------------------------------
echo ""
echo "=== ARCHITECTURE.md: Cross-references ==="

check_path "ARCHITECTURE.md" "CLAUDE.md"

# --------------------------------------------------------------------------
# ARCHITECTURE.md — Infrastructure components (verify directories exist)
# --------------------------------------------------------------------------
echo ""
echo "=== ARCHITECTURE.md: Infrastructure components ==="

# ARCHITECTURE.md references these components implicitly via names.
# Verify the directories that correspond to the components listed in the table.
check_path "ARCHITECTURE.md" "kubernetes/infrastructure/gateway-api/"
check_path "ARCHITECTURE.md" "kubernetes/infrastructure/cert-manager/"
check_path "ARCHITECTURE.md" "kubernetes/infrastructure/traefik/"
check_path "ARCHITECTURE.md" "kubernetes/infrastructure/nfs-provisioner/"
check_path "ARCHITECTURE.md" "kubernetes/infrastructure/kyverno/"
check_path "ARCHITECTURE.md" "kubernetes/infrastructure/monitoring/"
check_path "ARCHITECTURE.md" "kubernetes/infrastructure/adguard/"

# ARCHITECTURE.md references these paths/sections:
# "Register new apps in kubernetes/apps/kustomization.yaml"
check_path "ARCHITECTURE.md" "kubernetes/apps/kustomization.yaml"

# "infrastructure-config/" referenced in TLS and CRD bootstrapping sections
check_path "ARCHITECTURE.md" "kubernetes/infrastructure-config/"

# --------------------------------------------------------------------------
# README.md — file references
# --------------------------------------------------------------------------
echo ""
echo "=== README.md: File references ==="

# ".sops.yaml" — "add it to .sops.yaml"
check_path "README.md" ".sops.yaml"

# "terraform/secrets.enc.json"
check_path "README.md" "terraform/secrets.enc.json"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
