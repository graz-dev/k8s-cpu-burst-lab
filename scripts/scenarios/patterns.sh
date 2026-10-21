# shellcheck shell=bash
# patterns.sh - ./lab.sh sidecar | controller | operator | vpa
#
# Applies one pattern, streams the log of whatever does the resizing, and shows
# the resize landing: Pod conditions clear and status.containerStatuses[].resources
# reports the steady CPU, with restartCount 0.

PATTERN_SELECTOR="app.kubernetes.io/name=petclinic"
LOG_PID=""
LAST_PHASE=""

stop_log_stream() {
  if [ -n "${LOG_PID}" ]; then
    kill "${LOG_PID}" 2>/dev/null || true
    wait "${LOG_PID}" 2>/dev/null || true
    LOG_PID=""
  fi
}

# start_log_stream PATTERN POD: follow the log of the component that resizes.
start_log_stream() {
  local pattern="$1" pod="$2"
  case "${pattern}" in
    sidecar)
      kubectl logs -f -n "${NS_DEMO}" "${pod}" -c startup-resizer > >(sed -u 's/^/    | /') 2>&1 &
      ;;
    controller)
      kubectl logs -f -n "${NS_DEMO}" deployment/startup-boost-controller > >(sed -u 's/^/    | /') 2>&1 &
      ;;
    operator)
      kubectl logs -f -n "${NS_OPERATOR}" deployment/startup-boost-operator --since=1s \
        > >(awk -F'\t' '/[Rr]esiz|[Ss]tabiliz/ {print "    | " $1 " " $2 " " $3; fflush()}') 2>&1 &
      ;;
    vpa)
      kubectl logs -f -n kube-system deployment/vpa-updater --since=1s \
        > >(grep --line-buffered "${NS_DEMO}/" | awk '{print "    | " substr($0, 1, 160); fflush()}') 2>&1 &
      ;;
  esac
  LOG_PID=$!
}

# The line each log prints once the resize is done or requested.
log_marker() {
  case "$1" in
    sidecar | controller) echo "resize complete" ;;
    operator) echo "Resize complete" ;;
    vpa) echo "In-place patched pod" ;;
  esac
}

_log_has_marker() { # PATTERN POD
  case "$1" in
    sidecar) kubectl logs -n "${NS_DEMO}" "$2" -c startup-resizer --tail=100 2>/dev/null ;;
    controller) kubectl logs -n "${NS_DEMO}" deployment/startup-boost-controller --tail=100 2>/dev/null ;;
    operator) kubectl logs -n "${NS_OPERATOR}" deployment/startup-boost-operator --tail=100 2>/dev/null ;;
    vpa) kubectl logs -n kube-system deployment/vpa-updater --tail=200 2>/dev/null ;;
  esac | grep -q "$(log_marker "$1")"
}

# note_phase: print and record a StartupBoostPolicy phase change (operator only).
note_phase() {
  local p
  [ "${PATTERN}" = "operator" ] || return 0
  p="$(kubectl get startupboostpolicies -n "${NS_DEMO}" \
    -o jsonpath='{.items[0].status.boostedPods[0].phase}' 2>/dev/null || true)"
  if [ -n "${p}" ] && [ "${p}" != "${LAST_PHASE}" ]; then
    LAST_PHASE="${p}"
    info "    policy phase: ${p}"
    res_event "phase_${p}"
  fi
}

_ready_note() { # POD
  note_phase
  [ "$(kubectl get pod "$1" -n "${NS_DEMO}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

_spec_changed_note() { # POD INITIAL
  note_phase
  [ "$(spec_cpu "${NS_DEMO}" "$1" limits)" != "$2" ]
}

_phase_steady() {
  note_phase
  [ "${LAST_PHASE}" = "Steady" ]
}

# resize_annotation_time POD: when the controller or the operator says it resized the Pod.
resize_annotation_time() {
  local t
  t="$(kubectl get pod "$1" -n "${NS_DEMO}" -o jsonpath='{.metadata.annotations.startup\.boost\.io/resized-at}' 2>/dev/null || true)"
  [ -n "${t}" ] || t="$(kubectl get pod "$1" -n "${NS_DEMO}" -o jsonpath='{.metadata.annotations.startup-boost\.io/resized-at}' 2>/dev/null || true)"
  printf '%s' "${t}"
}

# observe_resize POD INITIAL_CPU [TIMEOUT]: wait for the resize to be requested and to land.
# resize_requested is the controller's or operator's own annotation time when there is
# one, otherwise the first moment the spec shows a CPU different from INITIAL_CPU.
observe_resize() {
  local pod="$1" initial="$2" timeout="${3:-180}" target at rc=0
  poll_until "${timeout}" 1 _spec_changed_note "${pod}" "${initial}" \
    || die "no resize was requested within ${timeout}s."
  at="$(resize_annotation_time "${pod}")"
  res_event resize_requested "${at:-$(ts)}"
  target="$(spec_cpu "${NS_DEMO}" "${pod}" limits)"
  info "    resize requested: spec cpu limit ${initial} -> ${target}"
  resize_wait "${pod}" "${NS_DEMO}" "${APP_CONTAINER}" "${target}" 120 1 || rc=$?
  [ "${rc}" -eq 0 ] || die "resize did not complete (resize_wait exit ${rc})."
  res_event resize_done
}

run_pattern() {
  local pattern="$1" pod old_pod initial_req total=4 created ready
  PATTERN="${pattern}"
  LAST_PHASE=""
  [ "${pattern}" = "vpa" ] && total=5
  preflight
  res_begin "${pattern}"
  step_init "${total}"

  step "reset namespace ${NS_DEMO} and install what the ${pattern} pattern needs"
  ns_recreate "${NS_DEMO}"
  case "${pattern}" in
    operator) ensure_operator ;;
    vpa) ensure_vpa ;;
  esac

  step "deploy petclinic at ${BOOST_CPU}"
  case "${pattern}" in
    sidecar | controller) show kubectl apply -k "${REPO_ROOT}/implementation-${pattern}" ;;
    operator) show kubectl apply -k "${REPO_ROOT}/implementation-operator/demo" ;;
    vpa) show kubectl apply -k "${REPO_ROOT}/implementation-vpa" ;;
  esac
  poll_until 120 1 _pod_exists "${NS_DEMO}" "${PATTERN_SELECTOR}" || die "the petclinic Pod was not created."
  pod="$(newest_pod "${NS_DEMO}" "${PATTERN_SELECTOR}")"
  res_set pod "${pod}"
  res_set cpu_start "$(spec_cpu "${NS_DEMO}" "${pod}" limits)"
  if [ "${pattern}" != "vpa" ]; then
    start_log_stream "${pattern}" "${pod}"
  fi

  step "wait for ${pod} to be Ready"
  poll_until 420 1 _ready_note "${pod}" || die "Pod ${pod} did not become Ready."
  created="$(pod_created_at "${NS_DEMO}" "${pod}")"
  ready="$(pod_ready_at "${NS_DEMO}" "${pod}")"
  res_event pod_created "${created}"
  res_event ready "${ready}"
  info "    created ${created}, Ready ${ready}"

  if [ "${pattern}" = "vpa" ]; then
    step "apply the VerticalPodAutoscaler (InPlaceOrRecreate) and wait for the resize"
    show kubectl apply -k "${REPO_ROOT}/implementation-vpa/policy"
    res_event vpa_applied
    start_log_stream vpa "${pod}"
    observe_resize "${pod}" "${BOOST_CPU}" 900
  else
    step "the ${pattern} shrinks CPU in place"
    observe_resize "${pod}" "${BOOST_CPU}" 180
  fi

  poll_until 20 1 _log_has_marker "${pattern}" "${pod}" || warn "log marker '$(log_marker "${pattern}")' not seen."
  if [ "${pattern}" = "operator" ]; then
    poll_until 30 1 _phase_steady || warn "policy did not reach phase Steady."
  fi
  stop_log_stream

  echo
  info "Result:"
  show kubectl get pod "${pod}" -n "${NS_DEMO}" -o jsonpath="{.status.containerStatuses[?(@.name==\"${APP_CONTAINER}\")].resources}{\"\\n\"}"
  info "restartCount: $(restart_count "${NS_DEMO}" "${pod}")"
  info "cpu.max: $(cgroup_file "${NS_DEMO}" "${pod}" cpu.max)"
  if [ "${pattern}" = "operator" ]; then
    show kubectl get startupboostpolicies -n "${NS_DEMO}" -o wide
    show kubectl get startupboostpolicies -n "${NS_DEMO}" -o jsonpath='{range .items[0].status.boostedPods[*]}{.name}{"  "}{.phase}{"\n"}{end}'
  fi

  res_set cpu_end "$(actual_cpu "${NS_DEMO}" "${pod}" limits)"
  res_set cpu_max_after "$(cgroup_file "${NS_DEMO}" "${pod}" cpu.max)"
  res_set restart_count "$(restart_count "${NS_DEMO}" "${pod}")"

  if [ "${pattern}" = "vpa" ]; then
    old_pod="${pod}"
    step "roll the Deployment and record the new Pod's initial CPU request"
    info "Hypothesis: with a recommendation in place, VPA admission starts new Pods at the recommended CPU, so the boost is gone."
    show kubectl rollout restart deployment/petclinic -n "${NS_DEMO}"
    res_event rollout_restart
    poll_until 120 1 _new_pod_exists "${old_pod}" || die "no new Pod after the rollout."
    pod="$(newest_pod "${NS_DEMO}" "${PATTERN_SELECTOR}")"
    res_set rollout.pod "${pod}"
    initial_req="$(spec_cpu "${NS_DEMO}" "${pod}" requests)"
    res_set rollout.initial_cpu_request "${initial_req}"
    res_set rollout.initial_cpu_limit "$(spec_cpu "${NS_DEMO}" "${pod}" limits)"
    info "    new Pod ${pod}: initial cpu request ${initial_req}, limit $(spec_cpu "${NS_DEMO}" "${pod}" limits)"
    poll_until 420 1 _ready_note "${pod}" || die "Pod ${pod} did not become Ready."
    res_event rollout_ready "$(pod_ready_at "${NS_DEMO}" "${pod}")"
    res_set rollout.spring_startup_s "$(spring_startup_seconds "${NS_DEMO}" "${pod}")"
    res_set rollout.cpu_limit_at_ready "$(actual_cpu "${NS_DEMO}" "${pod}" limits)"
    res_set rollout.restart_count "$(restart_count "${NS_DEMO}" "${pod}")"
    if [ "${initial_req}" = "${BOOST_CPU}" ]; then
      info "Observed: the new Pod started at ${BOOST_CPU}; the boost survived the rollout."
      res_set rollout.boost_kept true
    else
      info "Observed: the new Pod started at ${initial_req}, not ${BOOST_CPU}; VPA admission replaced the boost."
      res_set rollout.boost_kept false
    fi
  fi

  res_set notes.timing_resolution "1 second (Pod condition times and 1 s polling)"
  res_end
  pattern_summary "${pattern}"
}

_new_pod_exists() { # OLD_POD
  local p
  p="$(newest_pod "${NS_DEMO}" "${PATTERN_SELECTOR}")"
  [ -n "${p}" ] && [ "${p}" != "$1" ]
}

pattern_summary() {
  local f="${RES_FILE}" ready req done_t
  ready="$(jq -r '.events.ready' "${f}")"
  req="$(jq -r '.events.resize_requested' "${f}")"
  done_t="$(jq -r '.events.resize_done' "${f}")"
  res_md_row "| Run | Pattern | Ready to resize requested (s) | Resize requested to done (s) | Restarts | CPU limit at end |" "| ${RES_ID} | $1 | $(($(epoch_of "${req}") - $(epoch_of "${ready}"))) | $(($(epoch_of "${done_t}") - $(epoch_of "${req}"))) | $(jq -r '.restart_count' "${f}") | $(jq -r '.cpu_end' "${f}") |"
}
