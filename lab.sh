#!/usr/bin/env bash
# lab.sh - entry point for the CPU Burst Lab.
# Run ./lab.sh help for the commands. Set PAUSE=1 to wait for Enter between steps.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# shellcheck source=scripts/lib/common.sh
. "${REPO_ROOT}/scripts/lib/common.sh"
export RESIZE_LOG_PREFIX="[lab]"
# shellcheck source=scripts/lib/resize.sh
. "${REPO_ROOT}/scripts/lib/resize.sh"
# shellcheck source=scripts/lib/results.sh
. "${REPO_ROOT}/scripts/lib/results.sh"
# shellcheck source=scripts/lib/images.sh
. "${REPO_ROOT}/scripts/lib/images.sh"
# shellcheck source=scripts/lib/load.sh
. "${REPO_ROOT}/scripts/lib/load.sh"
# shellcheck source=scripts/scenarios/patterns.sh
. "${REPO_ROOT}/scripts/scenarios/patterns.sh"
# shellcheck source=scripts/scenarios/manual-resize.sh
. "${REPO_ROOT}/scripts/scenarios/manual-resize.sh"
# shellcheck source=scripts/scenarios/compare.sh
. "${REPO_ROOT}/scripts/scenarios/compare.sh"
# shellcheck source=scripts/scenarios/stabilization.sh
. "${REPO_ROOT}/scripts/scenarios/stabilization.sh"
# shellcheck source=scripts/scenarios/jvm-cpus.sh
. "${REPO_ROOT}/scripts/scenarios/jvm-cpus.sh"
# shellcheck source=scripts/scenarios/watch.sh
. "${REPO_ROOT}/scripts/scenarios/watch.sh"

trap stop_log_stream EXIT

usage() {
  cat <<'EOF'
Usage: ./lab.sh <command> [options]

Cluster
  up                          kind cluster, metrics-server, VPA, monitoring, preloaded images
  down                        delete the cluster
  reset                       delete every lab namespace, keep the cluster and monitoring

Patterns (each runs end to end)
  sidecar | controller | operator | vpa

Demos and measurements
  compare [--parallel]        steady vs peak vs boost
  manual-resize               one resize by hand, cgroup before and after
  stabilization               operator with stabilizationSeconds 0, then 30, under load
  jvm-cpus                    with and without -XX:ActiveProcessorCount after the resize

Observe
  watch [namespace] [--once]  live table of Pods
  results [--md]              browse measurements (interactive); --md prints markdown

Environment
  PAUSE=1                     wait for Enter before every step
  LOAD_VUS, LOAD_DURATION     k6 virtual users and duration (stabilization, jvm-cpus)
  GRAFANA_HOST_PORT           host port for Grafana at ./lab.sh up (default 3000)
EOF
}

cmd_up() {
  preflight_tools
  preflight_cgroup_v2
  preflight_host_size
  GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT:-3000}" \
    "${REPO_ROOT}/scripts/setup-cluster.sh" --with-vpa --with-monitoring
  preload_images
  info "Cluster ready. Try: ./lab.sh manual-resize"
}

cmd_down() {
  require_tool kind
  "${REPO_ROOT}/scripts/teardown-cluster.sh"
}

cmd_reset() {
  local ns
  preflight_tools
  preflight_cluster
  for ns in ${LAB_NAMESPACES}; do
    info "deleting namespace ${ns}"
    kubectl delete namespace "${ns}" --ignore-not-found --wait=true >/dev/null
  done
}

cmd_results() {
  if [ "${1:-}" != "--md" ]; then
    require_tool python3
    exec python3 "${REPO_ROOT}/scripts/results-tui.py" "${RESULTS_DIR}"
  fi
  require_tool jq
  local f listing
  if ! ls "${RESULTS_DIR}"/*.json >/dev/null 2>&1; then
    info "No results yet. Run a scenario first."
    return 0
  fi
  # The latest file per scenario.
  listing="$(for f in "${RESULTS_DIR}"/*.json; do printf '%s\t%s\n' "$(jq -r .scenario "${f}")" "${f}"; done)"
  for f in $(printf '%s\n' "${listing}" | sort | awk -F'\t' '{last[$1] = $2} END {for (k in last) print last[k]}' | sort); do
    printf '\n### %s (%s)\n\n| Key | Value |\n|---|---|\n' "$(jq -r .scenario "${f}")" "$(basename "${f}")"
    jq -r 'paths(scalars) as $p | "| \($p | map(tostring) | join(".")) | \(getpath($p)) |"' "${f}"
  done
}

main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "${cmd}" in
    up) cmd_up ;;
    down) cmd_down ;;
    reset) cmd_reset ;;
    sidecar | controller | operator | vpa) run_pattern "${cmd}" ;;
    compare) run_compare "$@" ;;
    manual-resize) run_manual_resize ;;
    stabilization) run_stabilization ;;
    jvm-cpus) run_jvm_cpus ;;
    watch) run_watch "$@" ;;
    results) cmd_results "$@" ;;
    help | -h | --help) usage ;;
    *)
      usage >&2
      die "unknown command '${cmd}'."
      ;;
  esac
}

main "$@"
