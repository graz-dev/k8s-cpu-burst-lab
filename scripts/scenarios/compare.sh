# shellcheck shell=bash
# compare.sh - ./lab.sh compare [--parallel]
# The same app three ways: sized for the steady state (300m), sized for the
# peak (1500m), and started at 1500m then shrunk by the operator after 30 s.
# By default the Deployments start one at a time, each Ready and settled before
# the next, so they do not compete for host CPU.

COMPARE_VARIANTS="steady peak boost"
COMPARE_HOLD_SECONDS=180

# cpu_millicores NS POD: CPU used over a 5 s sample, from cpu.stat usage_usec.
cpu_millicores() {
  local a b t0 t1
  t0="$(epoch_now)"
  a="$(cpu_stat_value "$1" "$2" usage_usec)"
  sleep 5
  b="$(cpu_stat_value "$1" "$2" usage_usec)"
  t1="$(epoch_now)"
  awk -v a="${a:-0}" -v b="${b:-0}" -v dt="$((t1 - t0))" 'BEGIN { printf "%d", (b - a) / (dt * 1000) }'
}

# wait_cpu_settled NS POD THRESHOLD_MILLICORES TIMEOUT: two consecutive samples below the threshold.
# Returns 1 on timeout.
wait_cpu_settled() {
  local ns="$1" pod="$2" threshold="$3" deadline low=0 m
  deadline=$(($(epoch_now) + $4))
  while [ "$(epoch_now)" -lt "${deadline}" ]; do
    m="$(cpu_millicores "${ns}" "${pod}")"
    if [ "${m}" -lt "${threshold}" ]; then
      low=$((low + 1))
      [ "${low}" -ge 2 ] && return 0
    else
      low=0
    fi
  done
  return 1
}

# compare_measure VARIANT POD: numbers taken as soon as the Pod is seen Ready.
compare_measure() {
  local v="$1" pod="$2" ns="${NS_COMPARE}" ready created
  created="$(pod_created_at "${ns}" "${pod}")"
  ready="$(pod_ready_at "${ns}" "${pod}")"
  res_set "variants.${v}.pod" "${pod}"
  res_event "${v}_pod_created" "${created}"
  res_event "${v}_ready" "${ready}"
  res_set "variants.${v}.ready_seconds" "$(($(epoch_of "${ready}") - $(epoch_of "${created}")))"
  res_set "variants.${v}.spring_startup_seconds" "$(spring_startup_seconds "${ns}" "${pod}")"
  res_set "variants.${v}.nr_throttled_at_ready" "$(cpu_stat_value "${ns}" "${pod}" nr_throttled)"
  res_set "variants.${v}.throttled_usec_at_ready" "$(cpu_stat_value "${ns}" "${pod}" throttled_usec)"
  res_set "variants.${v}.stat_read_delay_seconds" "$(($(epoch_now) - $(epoch_of "${ready}")))"
  info "    ${v}: Ready in $(($(epoch_of "${ready}") - $(epoch_of "${created}"))) s, Spring reports $(spring_startup_seconds "${ns}" "${pod}") s, nr_throttled $(cpu_stat_value "${ns}" "${pod}" nr_throttled)"
}

_boost_resized() { # POD
  [ "$(spec_cpu "${NS_COMPARE}" "$1" limits)" = "${STEADY_CPU}" ]
}

run_compare() {
  local mode="sequential" arg v pod ns="${NS_COMPARE}" sel ready_e
  for arg in "$@"; do
    case "${arg}" in
      --parallel) mode="parallel" ;;
      *) die "unknown option '${arg}' (expected --parallel)." ;;
    esac
  done
  preflight
  res_begin compare
  res_set mode "${mode}"
  step_init 4

  step "reset ${ns} and make sure the operator is installed"
  ns_recreate "${ns}"
  ensure_operator
  kubectl apply -f "${REPO_ROOT}/scenarios/compare/namespace.yaml" >/dev/null

  step "start the three Deployments (${mode})"
  if [ "${mode}" = "parallel" ]; then
    show kubectl apply -k "${REPO_ROOT}/scenarios/compare"
  fi
  for v in ${COMPARE_VARIANTS}; do
    sel="app.kubernetes.io/name=petclinic,lab.variant=${v}"
    if [ "${mode}" = "sequential" ]; then
      show kubectl apply -k "${REPO_ROOT}/scenarios/compare/${v}"
    fi
    pod="$(wait_pod_ready "${ns}" "${sel}")"
    compare_measure "${v}" "${pod}"
    if [ "${mode}" = "sequential" ]; then
      if [ "${v}" = "boost" ]; then
        poll_until 180 1 _boost_resized "${pod}" || die "the operator did not resize ${pod}."
        resize_wait "${pod}" "${ns}" "${APP_CONTAINER}" "${STEADY_CPU}" 120 1 || die "resize of ${pod} did not complete."
        res_event boost_resize_done
      fi
      if wait_cpu_settled "${ns}" "${pod}" 100 240; then
        res_set "variants.${v}.settled" true
      else
        warn "${v} did not settle below 100m within 240 s; continuing."
        res_set "variants.${v}.settled" false
      fi
    fi
  done

  step "hold for ${COMPARE_HOLD_SECONDS} s after Ready and read the CPU request"
  for v in ${COMPARE_VARIANTS}; do
    sel="app.kubernetes.io/name=petclinic,lab.variant=${v}"
    pod="$(newest_pod "${ns}" "${sel}")"
    ready_e="$(epoch_of "$(pod_ready_at "${ns}" "${pod}")")"
    wait_until_epoch $((ready_e + COMPARE_HOLD_SECONDS))
    res_set "variants.${v}.cpu_request_after_hold" "$(spec_cpu "${ns}" "${pod}" requests)"
    res_set "variants.${v}.cpu_limit_actual_after_hold" "$(actual_cpu "${ns}" "${pod}" limits)"
    res_set "variants.${v}.restart_count" "$(restart_count "${ns}" "${pod}")"
    res_set "variants.${v}.nr_throttled_after_hold" "$(cpu_stat_value "${ns}" "${pod}" nr_throttled)"
    res_set "variants.${v}.throttled_usec_after_hold" "$(cpu_stat_value "${ns}" "${pod}" throttled_usec)"
  done

  step "summary"
  res_end
  compare_summary
}

compare_summary() {
  local f="${RES_FILE}" v header="| Run | Mode | Variant | Ready (s) | Spring startup (s) | nr_throttled at Ready | throttled_usec at Ready | CPU request after ${COMPARE_HOLD_SECONDS} s | Restarts |"
  info ""
  info "${header}"
  info "|---|---|---|---|---|---|---|---|---|"
  for v in ${COMPARE_VARIANTS}; do
    local row
    row="$(jq -r --arg v "${v}" --arg id "${RES_ID}" '
      .variants[$v] as $x
      | "| \($id) | \(.mode) | \($v) | \($x.ready_seconds) | \($x.spring_startup_seconds) | \($x.nr_throttled_at_ready) | \($x.throttled_usec_at_ready) | \($x.cpu_request_after_hold) | \($x.restart_count) |"' "${f}")"
    info "${row}"
    res_md_row "${header}" "${row}"
  done
}
