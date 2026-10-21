# shellcheck shell=bash
# stabilization.sh - ./lab.sh stabilization
# The operator shrinks petclinic right at Ready (stabilizationSeconds 0, run A)
# or 30 s after Ready (run B), while k6 sends load that starts as soon as the Pod
# is Ready. For each run it records the throttling ratio and the k6 latency for
# the 2 minutes after the resize.
#
# Both runs use the same Grafana window, anchored on the resize: 60 s before to
# 120 s after, so two screenshots can sit side by side on the same time scale.

STAB_AFTER_SECONDS=120
STAB_BEFORE_SECONDS=60

_resized_spec() { # POD
  [ "$(spec_cpu "${NS_STABILIZATION}" "$1" limits)" = "${STEADY_CPU}" ]
}

# stabilization_run LABEL STABILIZATION_SECONDS POLICY_FILE
stabilization_run() {
  local label="$1" stab="$2" policy="$3" ns="${NS_STABILIZATION}" pod
  local ready ready_e anchor_e from_e to_e p0 t0 p1 t1 win r="runs.$1"

  ns_recreate "${ns}"
  kubectl apply -k "${REPO_ROOT}/scenarios/stabilization" >/dev/null
  show kubectl apply -n "${ns}" -f "${policy}"
  pod="$(wait_pod_ready "${ns}" "app.kubernetes.io/name=petclinic")"
  ready="$(pod_ready_at "${ns}" "${pod}")"
  ready_e="$(epoch_of "${ready}")"
  res_set "${r}.pod" "${pod}"
  res_set "${r}.stabilization_seconds" "${stab}"
  res_event "${label}_ready" "${ready}"

  info "    Ready; starting k6 (${LOAD_VUS} VUs)"
  k6_start "${ns}" "http://petclinic.${ns}.svc:8080" $((stab + STAB_AFTER_SECONDS + 30))
  res_event "${label}_load_started"

  info "    waiting for the resize (stabilizationSeconds ${stab})"
  poll_until $((stab + 120)) 1 _resized_spec "${pod}" || die "the operator did not resize ${pod}."
  resize_wait "${pod}" "${ns}" "${APP_CONTAINER}" "${STEADY_CPU}" 120 1 || die "resize of ${pod} did not complete."
  anchor_e="$(epoch_now)"
  res_event "${label}_resize_done" "$(ts "${anchor_e}")"
  res_set "${r}.resize_requested_annotation" "$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.metadata.annotations.startup\.boost\.io/resized-at}')"
  res_set "${r}.ready_to_resize_done_seconds" "$((anchor_e - ready_e))"

  from_e=$((anchor_e - STAB_BEFORE_SECONDS))
  to_e=$((anchor_e + STAB_AFTER_SECONDS))
  res_set "${r}.window.from" "$(ts "${from_e}")"
  res_set "${r}.window.to" "$(ts "${to_e}")"
  res_set "${r}.window.seconds" "$((STAB_BEFORE_SECONDS + STAB_AFTER_SECONDS))"

  p0="$(cpu_stat_value "${ns}" "${pod}" nr_periods)"
  t0="$(cpu_stat_value "${ns}" "${pod}" nr_throttled)"
  info "    measuring ${STAB_AFTER_SECONDS} s after the resize"
  wait_until_epoch "${to_e}"
  p1="$(cpu_stat_value "${ns}" "${pod}" nr_periods)"
  t1="$(cpu_stat_value "${ns}" "${pod}" nr_throttled)"
  res_set "${r}.throttle.nr_periods_delta" "$((p1 - p0))"
  res_set "${r}.throttle.nr_throttled_delta" "$((t1 - t0))"
  res_set "${r}.throttle.ratio_after" "$(awk -v a="$((t1 - t0))" -v b="$((p1 - p0))" 'BEGIN { if (b > 0) printf "%.4f", a / b; else print "null" }')"

  k6_wait "${ns}" $((stab + STAB_AFTER_SECONDS + 120))
  win="$(k6_window "${anchor_e}" "${to_e}")"
  res_set "${r}.k6_window.requests" "$(printf '%s' "${win}" | jq '.requests')"
  res_set "${r}.k6_window.errors" "$(printf '%s' "${win}" | jq '.errors')"
  res_set "${r}.k6_window.p50_ms" "$(printf '%s' "${win}" | jq '.p50_ms')"
  res_set "${r}.k6_window.p95_ms" "$(printf '%s' "${win}" | jq '.p95_ms')"
  res_set "${r}.k6_window.method" "nearest-rank over requests started in the window"
  res_set "${r}.k6_whole_run" "$(k6_summary)"
  res_set "${r}.restart_count" "$(restart_count "${ns}" "${pod}")"
  k6_cleanup "${ns}"
  info "    ${label}: k6 p95 $(printf '%s' "${win}" | jq '.p95_ms') ms in the window"
}

run_stabilization() {
  preflight
  res_begin stabilization
  res_set load.vus "${LOAD_VUS}"
  step_init 3

  step "make sure the operator is installed"
  ensure_operator

  step "run A: stabilizationSeconds 0 (shrink right at Ready)"
  stabilization_run a_0s 0 "${REPO_ROOT}/implementation-operator/config/samples/startupboostpolicy.yaml"

  step "run B: stabilizationSeconds 30 (shrink 30 s after Ready)"
  stabilization_run b_30s 30 "${REPO_ROOT}/implementation-operator/config/samples/startupboostpolicy-stabilized.yaml"

  res_end
  stabilization_summary
}

stabilization_summary() {
  local f="${RES_FILE}" header="| Run | stabilizationSeconds | Throttle ratio, 120 s after resize | k6 p50 (ms) | k6 p95 (ms) | Restarts |" row k
  info ""
  info "${header}"
  info "|---|---|---|---|---|---|"
  for k in a_0s b_30s; do
    row="$(jq -r --arg k "${k}" --arg id "${RES_ID}" '
      .runs[$k] as $x
      | "| \($id) \($k) | \($x.stabilization_seconds) | \($x.throttle.ratio_after) | \($x.k6_window.p50_ms) | \($x.k6_window.p95_ms) | \($x.restart_count) |"' "${f}")"
    info "${row}"
    res_md_row "${header}" "${row}"
  done
}
