# shellcheck shell=bash
# watch.sh - ./lab.sh watch [namespace] [--once]
# A refreshing table, one row per petclinic Pod, sized for a projector (86 columns).

watch_row() {
  printf '%-32s %-8s %-5s %-8s %-10s %-8s %s\n' "$@"
}

watch_table() { # [NAMESPACE]
  local ns_args pods name phase ready spec actual restarts thr ns
  if [ -n "${1:-}" ]; then
    ns_args="-n $1"
  else
    ns_args="-A"
  fi
  # shellcheck disable=SC2086
  pods="$(kubectl get pods ${ns_args} -l app.kubernetes.io/part-of=cpu-burst-lab -o json 2>/dev/null \
    | jq -r --arg c "${APP_CONTAINER}" '
        .items[] | select(.spec.containers | any(.name == $c))
        | [.metadata.namespace, .metadata.name, .status.phase,
           ((.status.conditions // [] | map(select(.type == "Ready")) | .[0].status // "False") | ascii_downcase),
           (.spec.containers | map(select(.name == $c)) | .[0].resources.limits.cpu // "-"),
           ((.status.containerStatuses // [] | map(select(.name == $c)) | .[0].resources.limits.cpu) // "-"),
           ((.status.containerStatuses // [] | map(select(.name == $c)) | .[0].restartCount) // 0 | tostring)]
        | @tsv')"
  watch_row POD PHASE READY "CPU SPEC" "CPU ACTUAL" RESTARTS THROTTLED
  [ -n "${pods}" ] || return 0
  while IFS="$(printf '\t')" read -r ns name phase ready spec actual restarts; do
    thr="-"
    if [ "${phase}" = "Running" ]; then
      thr="$(cpu_stat_value "${ns}" "${name}" nr_throttled 2>/dev/null || true)"
      [ -n "${thr}" ] || thr="-"
    fi
    watch_row "$(printf '%s' "${name}" | cut -c1-32)" "${phase}" "${ready}" "${spec}" "${actual}" "${restarts}" "${thr}"
  done <<EOF
${pods}
EOF
}

run_watch() {
  local ns="" once=0 arg interval="${WATCH_INTERVAL:-2}"
  for arg in "$@"; do
    case "${arg}" in
      --once) once=1 ;;
      *) ns="${arg}" ;;
    esac
  done
  preflight_tools
  preflight_cluster
  if [ "${once}" = "1" ]; then
    watch_table "${ns}"
    return 0
  fi
  while :; do
    printf '\033[H\033[2J'
    watch_table "${ns}"
    sleep "${interval}"
  done
}
