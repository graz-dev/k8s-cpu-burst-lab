# shellcheck shell=bash
# jvm-cpus.sh - ./lab.sh jvm-cpus
# Two boost Deployments, identical except one sets -XX:ActiveProcessorCount=1.
# Both start at 1500m (the JVM sizes its thread pools for 2 CPUs) and are shrunk
# to 300m by the operator after 30 s. The same k6 load then runs against each,
# one after the other. If the numbers do not differ, that is the result.

JVM_VARIANTS="default cpus1"

_jvm_resized() { # POD
  [ "$(spec_cpu "${NS_JVM}" "$1" limits)" = "${STEADY_CPU}" ]
}

# detected_cpus NS POD: "available" from the gc+init line "CPUs: N total, M available".
detected_cpus() {
  kubectl logs -n "$1" "$2" -c "${APP_CONTAINER}" 2>/dev/null \
    | sed -n 's/.*CPUs: [0-9]* total, \([0-9]*\) available.*/\1/p' | head -n1
}

run_jvm_cpus() {
  local ns="${NS_JVM}" v pod p0 t0 p1 t1 s_e e_e win
  preflight
  res_begin jvm-cpus
  res_set load.vus "${LOAD_VUS}"
  res_set load.duration_seconds "${LOAD_DURATION}"
  step_init 3

  step "reset ${ns}, make sure the operator is installed, create the policy (stabilizationSeconds 30)"
  ns_recreate "${ns}"
  ensure_operator
  kubectl apply -f "${REPO_ROOT}/scenarios/jvm-cpus/namespace.yaml" >/dev/null
  kubectl apply -f "${REPO_ROOT}/scenarios/jvm-cpus/startupboostpolicy.yaml" >/dev/null

  step "start the two variants one at a time and wait for the resize to 300m"
  for v in ${JVM_VARIANTS}; do
    show kubectl apply -k "${REPO_ROOT}/scenarios/jvm-cpus/${v}"
    pod="$(wait_pod_ready "${ns}" "app.kubernetes.io/name=petclinic,lab.variant=${v}")"
    res_set "variants.${v}.pod" "${pod}"
    res_set "variants.${v}.detected_cpus_at_startup" "$(detected_cpus "${ns}" "${pod}")"
    res_set "variants.${v}.java_tool_options" "$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath="{.spec.containers[?(@.name==\"${APP_CONTAINER}\")].env[?(@.name==\"JAVA_TOOL_OPTIONS\")].value}")"
    poll_until 180 1 _jvm_resized "${pod}" || die "the operator did not resize ${pod}."
    resize_wait "${pod}" "${ns}" "${APP_CONTAINER}" "${STEADY_CPU}" 120 1 || die "resize of ${pod} did not complete."
    info "    ${v}: JVM detected $(detected_cpus "${ns}" "${pod}") CPUs at startup, now at ${STEADY_CPU}"
  done

  step "run the same k6 load against each variant"
  for v in ${JVM_VARIANTS}; do
    pod="$(newest_pod "${ns}" "app.kubernetes.io/name=petclinic,lab.variant=${v}")"
    p0="$(cpu_stat_value "${ns}" "${pod}" nr_periods)"
    t0="$(cpu_stat_value "${ns}" "${pod}" nr_throttled)"
    s_e="$(epoch_now)"
    res_event "${v}_load_started"
    k6_start "${ns}" "http://petclinic-${v}.${ns}.svc:8080" "${LOAD_DURATION}"
    k6_wait "${ns}" $((LOAD_DURATION + 180))
    e_e="$(epoch_now)"
    res_event "${v}_load_ended"
    p1="$(cpu_stat_value "${ns}" "${pod}" nr_periods)"
    t1="$(cpu_stat_value "${ns}" "${pod}" nr_throttled)"
    res_set "variants.${v}.throttle.nr_periods_delta" "$((p1 - p0))"
    res_set "variants.${v}.throttle.nr_throttled_delta" "$((t1 - t0))"
    res_set "variants.${v}.throttle.ratio_during_load" "$(awk -v a="$((t1 - t0))" -v b="$((p1 - p0))" 'BEGIN { if (b > 0) printf "%.4f", a / b; else print "null" }')"
    win="$(k6_window "${s_e}" "${e_e}")"
    res_set "variants.${v}.k6_window.requests" "$(printf '%s' "${win}" | jq '.requests')"
    res_set "variants.${v}.k6_window.p50_ms" "$(printf '%s' "${win}" | jq '.p50_ms')"
    res_set "variants.${v}.k6_window.p95_ms" "$(printf '%s' "${win}" | jq '.p95_ms')"
    res_set "variants.${v}.k6_whole_run" "$(k6_summary)"
    res_set "variants.${v}.restart_count" "$(restart_count "${ns}" "${pod}")"
    k6_cleanup "${ns}"
  done

  res_end
  jvm_summary
}

jvm_summary() {
  local f="${RES_FILE}" header="| Run | Variant | CPUs detected at startup | Throttle ratio during load | k6 p50 (ms) | k6 p95 (ms) | Restarts |" v row
  info ""
  info "${header}"
  info "|---|---|---|---|---|---|---|"
  for v in ${JVM_VARIANTS}; do
    row="$(jq -r --arg v "${v}" --arg id "${RES_ID}" '
      .variants[$v] as $x
      | "| \($id) | \($v) | \($x.detected_cpus_at_startup) | \($x.throttle.ratio_during_load) | \($x.k6_window.p50_ms) | \($x.k6_window.p95_ms) | \($x.restart_count) |"' "${f}")"
    info "${row}"
    res_md_row "${header}" "${row}"
  done
}
