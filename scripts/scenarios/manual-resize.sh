# shellcheck shell=bash
# manual-resize.sh - ./lab.sh manual-resize
# One petclinic Pod at 1500m, resized to 300m by hand. Everything shown is read
# from the live Pod and its cgroup; nothing is hardcoded.

run_manual_resize() {
  local pod ns="${NS_MANUAL}" before after rc=0
  preflight
  res_begin manual-resize
  step_init 5

  step "deploy one petclinic Pod at ${BOOST_CPU}"
  ns_recreate "${ns}"
  show kubectl apply -k "${REPO_ROOT}/scenarios/manual-resize"
  pod="$(wait_pod_ready "${ns}" "app.kubernetes.io/name=petclinic")"
  res_set pod "${pod}"
  res_event pod_created "$(pod_created_at "${ns}" "${pod}")"
  res_event ready "$(pod_ready_at "${ns}" "${pod}")"
  info "Pod ${pod} is Ready"

  step "read the CPU limit from the container's cgroup, before"
  before="$(cgroup_file "${ns}" "${pod}" cpu.max)"
  info "$ kubectl exec ${pod} -- cat /sys/fs/cgroup/cpu.max"
  info "${before}"
  info "$ kubectl get pod ${pod} -o jsonpath='{.status.containerStatuses[?(@.name==\"${APP_CONTAINER}\")].resources}'"
  actual_resources "${ns}" "${pod}"
  res_set before.cpu_max "${before}"
  res_set before.cpu_request "$(actual_cpu "${ns}" "${pod}" requests)"
  res_set before.cpu_limit "$(actual_cpu "${ns}" "${pod}" limits)"

  step "resize to ${STEADY_CPU} through the resize subresource"
  info "$ kubectl patch pod ${pod} --subresource resize --patch '{\"spec\":{\"containers\":[{\"name\":\"${APP_CONTAINER}\",\"resources\":{\"requests\":{\"cpu\":\"${STEADY_CPU}\"},\"limits\":{\"cpu\":\"${STEADY_CPU}\"}}}]}}'"
  res_event resize_requested
  resize_patch "${pod}" "${ns}" "${APP_CONTAINER}" "${STEADY_CPU}"

  step "poll the Pod conditions until the resize is done"
  resize_wait "${pod}" "${ns}" "${APP_CONTAINER}" "${STEADY_CPU}" 120 1 || rc=$?
  [ "${rc}" -eq 0 ] || die "resize did not complete (resize_wait exit ${rc})."
  res_event resize_done
  info "$ kubectl get pod ${pod} -o jsonpath='{.status.conditions[*].type}'"
  kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.status.conditions[*].type}{"\n"}'

  step "read the cgroup and the Pod status again, after"
  after="$(cgroup_file "${ns}" "${pod}" cpu.max)"
  info "$ kubectl exec ${pod} -- cat /sys/fs/cgroup/cpu.max"
  info "${after}"
  info "$ kubectl get pod ${pod} -o jsonpath='{.status.containerStatuses[?(@.name==\"${APP_CONTAINER}\")].resources}'"
  actual_resources "${ns}" "${pod}"
  info "restartCount: $(restart_count "${ns}" "${pod}")"
  res_set after.cpu_max "${after}"
  res_set after.cpu_request "$(actual_cpu "${ns}" "${pod}" requests)"
  res_set after.cpu_limit "$(actual_cpu "${ns}" "${pod}" limits)"
  res_set restart_count "$(restart_count "${ns}" "${pod}")"

  res_end
  res_md_row "| Run | cpu.max before | cpu.max after | CPU limit after | Restarts |" \
    "| ${RES_ID} | ${before} | ${after} | $(actual_cpu "${ns}" "${pod}" limits) | $(restart_count "${ns}" "${pod}") |"
}

actual_resources() { # NS POD
  kubectl get pod "$2" -n "$1" \
    -o jsonpath="{.status.containerStatuses[?(@.name==\"${APP_CONTAINER}\")].resources}{\"\\n\"}"
}
