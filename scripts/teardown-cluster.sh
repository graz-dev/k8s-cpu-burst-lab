#!/usr/bin/env bash
# teardown-cluster.sh — Tear down the full cpu-burst-lab environment.
# Removes the kind cluster (and everything inside it), the local Docker image,
# and the Helm chart repos added during setup.
# Safe to run multiple times — every step is idempotent.
set -euo pipefail

CLUSTER_NAME="cpu-burst-lab"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        CPU Burst Lab — Teardown                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Delete the kind cluster ─────────────────────────────────────────────────
# Deleting the cluster removes all Kubernetes resources, namespaces, Helm
# releases inside the cluster, and the kubeconfig context automatically.
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "🗑️   Deleting kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "✅  Cluster deleted."
else
  echo "ℹ️   Cluster '${CLUSTER_NAME}' not found — skipping."
fi

# ── 2. Remove Helm repos added by setup ───────────────────────────────────────
for repo in metrics-server fairwinds-stable prometheus-community; do
  if helm repo list 2>/dev/null | awk '{print $1}' | grep -q "^${repo}$"; then
    echo "🗑️   Removing Helm repo '${repo}'..."
    helm repo remove "${repo}"
  fi
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Teardown complete. To rebuild from scratch:                 ║"
echo "║                                                              ║"
echo "║    ./scripts/setup-cluster.sh [--with-vpa] [--with-monitoring] ║"
echo "║    kubectl apply -k implementation-sidecar/                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
