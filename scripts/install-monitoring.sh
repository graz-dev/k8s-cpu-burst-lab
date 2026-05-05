#!/usr/bin/env bash
# install-monitoring.sh — Install Prometheus + Grafana (kube-prometheus-stack)
# and provision the CPU Burst Lab dashboard automatically via the Grafana sidecar.
#
# Grafana is exposed as NodePort 30300, which kind maps to localhost:3000 via
# the extraPortMappings in kind-config.yaml — no kubectl port-forward needed.
#
# Requires: helm, kubectl, cluster created with kind-config.yaml.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITORING_NAMESPACE="monitoring"
CHART_VERSION="84.5.0"   # kube-prometheus-stack; bump if a newer stable is available

echo "📊  Installing monitoring stack (Prometheus + Grafana)..."
echo "    Chart:     prometheus-community/kube-prometheus-stack ${CHART_VERSION}"
echo "    Namespace: ${MONITORING_NAMESPACE}"
echo ""

# ── Add chart repo ──────────────────────────────────────────────────────────────
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts --force-update &>/dev/null

# ── Install kube-prometheus-stack ──────────────────────────────────────────────
# Key settings for a 4-CPU kind cluster:
#   alertmanager disabled    — not needed for a demo
#   default dashboards off   — we provision our own via the sidecar ConfigMap
#   scrapeInterval=5s        — default 60s is too coarse to see the resize dip
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

echo "✅  Monitoring stack installed."

# ── Provision the CPU Burst Lab dashboard ──────────────────────────────────────
# The ConfigMap carries grafana_dashboard=1; the Grafana sidecar watches for
# this label across all namespaces and imports the dashboard automatically.
# The dashboard lives in the 'monitoring' namespace — it survives when you
# delete 'cpu-burst-demo' between implementation runs.
echo ""
echo "📈  Provisioning CPU Burst Lab dashboard..."
kubectl apply -f "${REPO_ROOT}/monitoring/grafana-dashboard.yaml"
echo "✅  Dashboard provisioned (sidecar will import it within ~30s)."

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Grafana is ready — no port-forward needed.                  ║"
echo "║                                                              ║"
echo "║  URL:       http://localhost:3000                            ║"
echo "║  Username:  admin  |  Password: admin                        ║"
echo "║  Dashboard: CPU Burst Lab — Startup Resize                   ║"
echo "║                                                              ║"
echo "║  Note: the monitoring namespace is independent of            ║"
echo "║  cpu-burst-demo — Grafana stays up when you delete the       ║"
echo "║  demo namespace between implementation runs.                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
