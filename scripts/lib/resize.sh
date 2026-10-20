# shellcheck shell=sh
# resize.sh - In-Place Pod Resize helpers.
#
# POSIX sh only. Sourced by the host scripts (lab.sh) and mounted into the
# sidecar and controller containers, so the "is the resize done" logic exists
# once. Needs kubectl v1.32 or later (--subresource=resize).
#
# Since v1.33 the resize status lives in Pod conditions, not in .status.resize:
#   PodResizePending    reason Infeasible or Deferred
#   PodResizeInProgress the kubelet is applying the change
# A resize is done when neither condition is present AND the resources the
# kubelet reports for the container (status.containerStatuses[].resources)
# equal the resources in the Pod spec.

RESIZE_LOG_PREFIX="${RESIZE_LOG_PREFIX:-[resize]}"

resize_log() {
  printf '%s %s\n' "${RESIZE_LOG_PREFIX}" "$*"
}

# resize_patch POD NAMESPACE CONTAINER CPU
# Sets requests.cpu and limits.cpu of one named container through the resize subresource.
resize_patch() {
  kubectl patch pod "$1" -n "$2" --subresource=resize --type=strategic \
    -p "{\"spec\":{\"containers\":[{\"name\":\"$3\",\"resources\":{\"requests\":{\"cpu\":\"$4\"},\"limits\":{\"cpu\":\"$4\"}}}]}}"
}

# resize_snapshot POD NAMESPACE CONTAINER
# Prints one line, fields separated by "|":
#   pending_status|pending_reason|in_progress_status|spec_req|spec_lim|actual_req|actual_lim
# Containers are always selected by name, never by index.
resize_snapshot() {
  kubectl get pod "$1" -n "$2" -o jsonpath="{.status.conditions[?(@.type==\"PodResizePending\")].status}|{.status.conditions[?(@.type==\"PodResizePending\")].reason}|{.status.conditions[?(@.type==\"PodResizeInProgress\")].status}|{.spec.containers[?(@.name==\"$3\")].resources.requests.cpu}|{.spec.containers[?(@.name==\"$3\")].resources.limits.cpu}|{.status.containerStatuses[?(@.name==\"$3\")].resources.requests.cpu}|{.status.containerStatuses[?(@.name==\"$3\")].resources.limits.cpu}"
}

# resize_is_done POD NAMESPACE CONTAINER [TARGET_CPU]
# Returns 0 when the resize has landed, 1 while it has not, 2 when the Pod
# cannot be read. With TARGET_CPU the actual limit must also equal it.
resize_is_done() {
  _snap="$(resize_snapshot "$1" "$2" "$3" 2>/dev/null)" || return 2
  IFS='|' read -r _pend _reason _prog _sreq _slim _areq _alim <<EOF
${_snap}
EOF
  [ -z "${_pend}${_prog}" ] || return 1
  [ -n "${_alim}" ] || return 1
  [ "${_sreq}" = "${_areq}" ] && [ "${_slim}" = "${_alim}" ] || return 1
  [ -z "${4:-}" ] || [ "${_alim}" = "$4" ] || return 1
  return 0
}

# resize_wait POD NAMESPACE CONTAINER TARGET_CPU TIMEOUT_SECONDS [INTERVAL_SECONDS]
# Polls resize_is_done until it succeeds. Returns 0 when done, 1 on timeout,
# 2 when the kubelet reports the resize as Infeasible.
resize_wait() {
  _deadline=$(( $(date +%s) + $5 ))
  _interval="${6:-1}"
  while :; do
    if resize_is_done "$1" "$2" "$3" "$4"; then
      _snap="$(resize_snapshot "$1" "$2" "$3")"
      IFS='|' read -r _pend _reason _prog _sreq _slim _areq _alim <<EOF
${_snap}
EOF
      resize_log "$1: resize complete, containerStatuses[${3}].resources cpu request=${_areq} limit=${_alim}"
      return 0
    fi
    _snap="$(resize_snapshot "$1" "$2" "$3" 2>/dev/null || true)"
    IFS='|' read -r _pend _reason _prog _sreq _slim _areq _alim <<EOF
${_snap}
EOF
    if [ "${_reason}" = "Infeasible" ]; then
      resize_log "$1: resize Infeasible"
      return 2
    fi
    if [ "$(date +%s)" -ge "${_deadline}" ]; then
      resize_log "$1: timeout, spec limit=${_slim} actual limit=${_alim} pending=${_pend:-none}/${_reason:-none} in-progress=${_prog:-none}"
      return 1
    fi
    sleep "${_interval}"
  done
}
