# shellcheck shell=bash
# load.sh - run the in-cluster k6 Job (scenarios/load) and read its numbers.

LOAD_VUS="${LOAD_VUS:-5}"
LOAD_DURATION="${LOAD_DURATION:-120}"   # seconds

# k6_start NS TARGET_URL DURATION_SECONDS: (re)create the k6 Job in NS.
k6_start() {
  local ns="$1" target="$2" duration="$3"
  kubectl delete job k6 -n "${ns}" --ignore-not-found --wait=true >/dev/null
  kubectl delete configmap k6-config -n "${ns}" --ignore-not-found >/dev/null
  kubectl create configmap k6-config -n "${ns}" \
    --from-literal=TARGET="${target}" \
    --from-literal=VUS="${LOAD_VUS}" \
    --from-literal=DURATION="${duration}s" >/dev/null
  kubectl apply -n "${ns}" -k "${REPO_ROOT}/scenarios/load" >/dev/null
}

_k6_finished() { # NS
  local s f
  s="$(kubectl get job k6 -n "$1" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  f="$(kubectl get job k6 -n "$1" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  [ "${s:-0}" -ge 1 ] || [ "${f:-0}" -ge 1 ]
}

# k6_wait NS TIMEOUT_SECONDS: block until the Job ends; save its log to K6_LOG.
k6_wait() {
  local ns="$1" timeout="$2"
  poll_until "${timeout}" 2 _k6_finished "${ns}" || die "the k6 Job did not finish within ${timeout}s."
  K6_LOG="$(mktemp)"
  kubectl logs job/k6 -n "${ns}" > "${K6_LOG}" 2>&1
  grep -q '^K6_SUMMARY ' "${K6_LOG}" || die "the k6 Job produced no summary (see: kubectl logs job/k6 -n ${ns})."
}

# k6_summary: the whole-run numbers k6 itself computed, as JSON.
k6_summary() {
  sed -n 's/^K6_SUMMARY //p' "${K6_LOG}"
}

# k6_window FROM_EPOCH TO_EPOCH: requests, error count and nearest-rank p50/p95 (ms)
# of the requests that started inside the window, as JSON.
k6_window() {
  sed -n 's/.*K6_POINT \([0-9]*\) \([0-9.]*\) \([0-9]*\).*/\1 \2 \3/p' "${K6_LOG}" \
    | jq -Rn --argjson from "$(($1 * 1000))" --argjson to "$(($2 * 1000))" '
        [inputs | split(" ") | {t: (.[0] | tonumber), d: (.[1] | tonumber), s: (.[2] | tonumber)}
         | select(.t >= $from and .t < $to)] as $p
        | ($p | map(.d) | sort) as $d
        | def rank($q): if ($d | length) == 0 then null else $d[((($d | length) * $q) | ceil) - 1] end;
          {requests: ($p | length), errors: ($p | map(select(.s != 200)) | length),
           p50_ms: rank(0.5), p95_ms: rank(0.95)}'
}

# k6_cleanup NS
k6_cleanup() {
  kubectl delete job k6 -n "$1" --ignore-not-found --wait=false >/dev/null
  [ -z "${K6_LOG:-}" ] || rm -f "${K6_LOG}"
}
