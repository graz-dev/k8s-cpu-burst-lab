#!/usr/bin/env bash
# setup-cluster.sh - Bootstrap the cpu-burst-lab kind cluster.
# Usage: ./scripts/setup-cluster.sh [--with-vpa]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="cpu-burst-lab"
WORKER_LABEL="demo/role=worker"
METRICS_SERVER_CHART_VERSION="3.14.0"
WITH_VPA=false
WITH_MONITORING=false

# ── Parse flags ────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --with-vpa)        WITH_VPA=true ;;
    --with-monitoring) WITH_MONITORING=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Prerequisite checks ────────────────────────────────────────────────────────
check_tool() {
  if ! command -v "$1" &>/dev/null; then
    echo "'$1' not found. Please install it and retry."
    exit 1
  fi
}
check_tool kind
check_tool kubectl
check_tool docker
check_tool helm   # needed for metrics-server & VPA

echo ""
echo "CPU Burst Lab: cluster bootstrap (Kubernetes v1.37, In-Place Pod Resize stable)"
echo ""

# ── Create the kind cluster ────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
else
  echo "Creating kind cluster '${CLUSTER_NAME}'..."
  # GRAFANA_HOST_PORT overrides the host port mapped to Grafana (default 3000).
  KIND_CONFIG="$(mktemp)"
  sed "s/hostPort: 3000/hostPort: ${GRAFANA_HOST_PORT:-3000}/" "${REPO_ROOT}/kind-config.yaml" > "${KIND_CONFIG}"
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${KIND_CONFIG}" \
    --wait 120s
  rm -f "${KIND_CONFIG}"
  echo "Cluster created."
fi

# ── Set kubectl context ────────────────────────────────────────────────────────
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── Label the worker node ──────────────────────────────────────────────────────
echo ""
echo "Labelling worker node with '${WORKER_LABEL}'..."
WORKER_NODE="$(kubectl get nodes --no-headers \
  -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl label node "${WORKER_NODE}" demo/role=worker --overwrite
echo "    Worker node: ${WORKER_NODE}"

# ── Report the server version ──────────────────────────────────────────────────
echo ""
echo "Server version: $(kubectl version -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['serverVersion']['gitVersion'])")"

# ── Install metrics-server ─────────────────────────────────────────────────────
echo ""
echo "Installing metrics-server (needed for kubectl top)..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update &>/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --version "${METRICS_SERVER_CHART_VERSION}" \
  --set args="{--kubelet-insecure-tls}" \
  --wait \
  --timeout 120s
echo "metrics-server installed."

# ── Optionally install VPA ─────────────────────────────────────────────────────
if [[ "${WITH_VPA}" == "true" ]]; then
  echo ""
  echo "Installing Vertical Pod Autoscaler..."
  bash "${REPO_ROOT}/implementation-vpa/install-vpa.sh"
fi

# ── Optionally install monitoring (Prometheus + Grafana) ───────────────────────
if [[ "${WITH_MONITORING}" == "true" ]]; then
  echo ""
  bash "${REPO_ROOT}/scripts/install-monitoring.sh"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "Cluster ready. Run a pattern with ./lab.sh sidecar|controller|operator|vpa"
