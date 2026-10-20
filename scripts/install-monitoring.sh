#!/usr/bin/env bash
# install-monitoring.sh - Install Prometheus + Grafana (kube-prometheus-stack)
# and provision the CPU Burst Lab dashboard automatically via the Grafana sidecar.
#
# Grafana is exposed as NodePort 30300, which kind maps to localhost:3000 via
# the extraPortMappings in kind-config.yaml - no kubectl port-forward needed.
#
# Requires: helm, kubectl, cluster created with kind-config.yaml.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITORING_NAMESPACE="monitoring"
CHART_VERSION="92.10.1"   # kube-prometheus-stack

echo "Installing monitoring stack (Prometheus + Grafana)..."
echo "    Chart:     prometheus-community/kube-prometheus-stack ${CHART_VERSION}"
echo "    Namespace: ${MONITORING_NAMESPACE}"
echo ""

# ── Add chart repo ──────────────────────────────────────────────────────────────
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts --force-update &>/dev/null

# ── Install kube-prometheus-stack ──────────────────────────────────────────────
# Key settings for a 4-CPU kind cluster:
#   alertmanager disabled    - not needed for a demo
#   default dashboards off   - we provision our own via the sidecar ConfigMap
#   scrapeInterval=5s        - default 60s is too coarse to see the resize dip
#   grafana.service.type=NodePort + nodePort=30300
#     → kind maps containerPort 30300 → hostPort 3000 (see kind-config.yaml)
#     → Grafana is available at http://localhost:3000 without port-forward
#   resource limits trimmed down so demo workloads coexist on the worker node
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace "${MONITORING_NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}" \
  --set alertmanager.enabled=false \
  --set grafana.adminPassword=admin \
  --set grafana.defaultDashboardsEnabled=false \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30300 \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.searchNamespace=ALL \
  --set grafana.persistence.enabled=false \
  --set "grafana.resources.requests.cpu=50m" \
  --set "grafana.resources.requests.memory=128Mi" \
  --set "grafana.resources.limits.cpu=200m" \
  --set "grafana.resources.limits.memory=256Mi" \
  --set prometheus.prometheusSpec.retention=2h \
  --set prometheus.prometheusSpec.scrapeInterval=5s \
  --set prometheus.prometheusSpec.evaluationInterval=5s \
  --set "prometheus.prometheusSpec.resources.requests.cpu=100m" \
  --set "prometheus.prometheusSpec.resources.requests.memory=256Mi" \
  --set "prometheus.prometheusSpec.resources.limits.cpu=500m" \
  --set "prometheus.prometheusSpec.resources.limits.memory=512Mi" \
  --set "kube-state-metrics.resources.requests.cpu=10m" \
  --set "kube-state-metrics.resources.requests.memory=32Mi" \
  --set "kube-state-metrics.resources.limits.cpu=50m" \
  --set "kube-state-metrics.resources.limits.memory=64Mi" \
  --set "prometheus-node-exporter.resources.requests.cpu=10m" \
  --set "prometheus-node-exporter.resources.requests.memory=16Mi" \
  --set "prometheus-node-exporter.resources.limits.cpu=50m" \
  --set "prometheus-node-exporter.resources.limits.memory=32Mi" \
  --wait \
  --timeout 300s

echo "Monitoring stack installed."

# ── Provision the CPU Burst Lab dashboard ──────────────────────────────────────
# monitoring/dashboard.json is the single source. It is wrapped in a ConfigMap
# labeled grafana_dashboard=1, which the Grafana sidecar imports from any
# namespace. The ConfigMap lives in 'monitoring', so it survives when the lab
# namespaces are deleted.
echo "Provisioning the CPU Burst Lab dashboard..."
kubectl create configmap cpu-burst-lab-dashboard \
  --namespace "${MONITORING_NAMESPACE}" \
  --from-file=cpu-burst-lab.json="${REPO_ROOT}/monitoring/dashboard.json" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 app.kubernetes.io/part-of=cpu-burst-lab -o yaml \
  | kubectl apply -f -

echo ""
echo "Grafana: http://localhost:${GRAFANA_HOST_PORT:-3000} (admin / admin), dashboard 'CPU Burst Lab'"
