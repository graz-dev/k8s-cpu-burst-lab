#!/usr/bin/env bash
# install-vpa.sh — Install the Vertical Pod Autoscaler stack using the
# official Helm chart from the Fairwinds charts repository.
# Requires: helm, kubectl, cluster context set to cpu-burst-lab.
set -euo pipefail

VPA_NAMESPACE="kube-system"
VPA_CHART_VERSION="4.11.0"  # latest stable as of Q2 2026; adjust if needed

echo "📈  Installing Vertical Pod Autoscaler..."
echo "    Chart version: ${VPA_CHART_VERSION}"
echo "    Namespace: ${VPA_NAMESPACE}"
echo ""

# ── Add the Fairwinds chart repo ───────────────────────────────────────────────
helm repo add fairwinds-stable https://charts.fairwinds.com/stable --force-update &>/dev/null

# ── Install / upgrade VPA ──────────────────────────────────────────────────────
# in-place-skip-disruption-budget: skip PDB checks for pods where all containers
# have restartPolicy=NotRequired — allows in-place resize of single-replica pods.
# NOTE: in-place-or-recreate is NOT a valid updater flag in VPA 1.6+; the
# InPlaceOrRecreate update mode is controlled per VPA object, not the updater.
helm upgrade --install vpa fairwinds-stable/vpa \
  --namespace "${VPA_NAMESPACE}" \
  --version "${VPA_CHART_VERSION}" \
  --set "recommender.enabled=true" \
  --set "updater.enabled=true" \
  --set "updater.extraArgs.in-place-skip-disruption-budget=true" \
  --set "admissionController.enabled=true" \
  --set "admissionController.generateCertificate=true" \
  --wait \
  --timeout 180s

echo ""
echo "✅  VPA installed. Verifying components..."
kubectl get pods -n "${VPA_NAMESPACE}" \
  -l "app.kubernetes.io/instance=vpa" \
  --no-headers

echo ""
echo "⚠️   Note: VPA Recommender needs ~5 minutes of metrics history before"
echo "    it can make confident recommendations. Apply the VPA object and"
echo "    deployment, then wait before expecting automatic resizes."
