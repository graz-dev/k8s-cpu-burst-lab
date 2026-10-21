#!/usr/bin/env bash
# teardown-cluster.sh - Delete the cpu-burst-lab kind cluster and the Helm repos
# added during setup. Safe to run more than once.
set -euo pipefail

CLUSTER_NAME="cpu-burst-lab"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Deleting kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "Cluster '${CLUSTER_NAME}' not found, nothing to delete."
fi

for repo in metrics-server fairwinds-stable prometheus-community; do
  if helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "${repo}"; then
    helm repo remove "${repo}" >/dev/null
  fi
done

echo "Teardown complete. Rebuild with ./lab.sh up"
