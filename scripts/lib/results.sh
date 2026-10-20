# shellcheck shell=bash
# results.sh - collect the measurements of one scenario run.
#
# res_begin <scenario>      start a run
# res_set <path> <value>    record a value; the path is dotted, e.g. variants.boost.ready_s
# res_event <name> [iso]    record a timestamp under events.<name> (default: now)
# res_end                   write results/<scenario>-<YYYYmmdd-HHMMSS>.json
# res_md_row <header> <row> append a row to results/<scenario>.md (header written once)
#
# Values that parse as JSON (numbers, true, false) are stored as such, anything
# else as a string. Nothing is written that was not measured: use "TBD".

RESULTS_DIR="${RESULTS_DIR:-${REPO_ROOT}/results}"

res_begin() {
  RES_SCENARIO="$1"
  RES_ID="$(date +%Y%m%d-%H%M%S)"
  RES_TMP="$(mktemp)"
  mkdir -p "${RESULTS_DIR}"
  res_set scenario "${RES_SCENARIO}"
  res_event started
  res_set cluster.kubernetes "$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion')"
  res_set cluster.worker_cpus "$(kubectl get nodes -l demo/role=worker -o jsonpath='{.items[0].status.allocatable.cpu}')"
  res_set cluster.worker_memory "$(kubectl get nodes -l demo/role=worker -o jsonpath='{.items[0].status.allocatable.memory}')"
}

res_set() {
  printf '%s\t%s\n' "$1" "$2" >> "${RES_TMP}"
}

res_event() {
  res_set "events.$1" "${2:-$(ts)}"
}

# res_end: prints the path of the JSON file it wrote.
res_end() {
  res_event ended
  RES_FILE="${RESULTS_DIR}/${RES_SCENARIO}-${RES_ID}.json"
  jq -Rn 'reduce (inputs | split("\t")) as $l ({};
            setpath($l[0] | split("."); ($l[1] as $v | try ($v | fromjson) catch $v)))' \
    < "${RES_TMP}" > "${RES_FILE}"
  rm -f "${RES_TMP}"
  info "results: ${RES_FILE}"
}

res_md_row() {
  local md="${RESULTS_DIR}/${RES_SCENARIO}.md"
  if [ ! -f "${md}" ]; then
    printf '%s\n' "$1" > "${md}"
    printf '%s\n' "$1" | head -n1 | sed 's/[^|]/-/g' >> "${md}"
  fi
  printf '%s\n' "$2" >> "${md}"
}
