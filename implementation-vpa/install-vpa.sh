#!/usr/bin/env bash
# install-vpa.sh - Install the Vertical Pod Autoscaler with the Fairwinds Helm chart.
# Chart 5.1.0 ships VPA 1.7.1. InPlaceOrRecreate is GA since VPA 1.6 and needs no
# feature gate. Requires: helm, kubectl, and the cpu-burst-lab context.
set -euo pipefail

VPA_NAMESPACE="kube-system"
VPA_CHART_VERSION="5.1.0"

echo "Installing Vertical Pod Autoscaler (chart ${VPA_CHART_VERSION}, namespace ${VPA_NAMESPACE})"

helm repo add fairwinds-stable https://charts.fairwinds.com/stable --force-update >/dev/null

# in-place-skip-disruption-budget: skip PodDisruptionBudget checks for in-place
# updates, which lets VPA resize a single-replica Deployment.
helm upgrade --install vpa fairwinds-stable/vpa \
  --namespace "${VPA_NAMESPACE}" \
  --version "${VPA_CHART_VERSION}" \
  --set recommender.enabled=true \
  --set updater.enabled=true \
  --set-string updater.extraArgs.in-place-skip-disruption-budget=true \
  --set admissionController.enabled=true \
  --set admissionController.generateCertificate=true \
  --wait \
  --timeout 180s

kubectl get pods -n "${VPA_NAMESPACE}" -l "app.kubernetes.io/instance=vpa" --no-headers
