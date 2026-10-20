# shellcheck shell=bash
# common.sh - constants and helpers shared by lab.sh and the scenarios.
# Works on bash 3.2 (macOS) and bash 5 (Linux): no associative arrays.

CLUSTER_NAME="${CLUSTER_NAME:-cpu-burst-lab}"
LAB_CONTEXT="kind-${CLUSTER_NAME}"
APP_CONTAINER="petclinic"
export BOOST_CPU="1500m"
export STEADY_CPU="300m"

NS_DEMO="cpu-burst-demo"
NS_COMPARE="cpu-burst-compare"
NS_MANUAL="cpu-burst-manual"
NS_STABILIZATION="cpu-burst-stabilization"
NS_JVM="cpu-burst-jvm"
NS_OPERATOR="cpu-burst-operator"
LAB_NAMESPACES="${NS_DEMO} ${NS_COMPARE} ${NS_MANUAL} ${NS_STABILIZATION} ${NS_JVM}"

# Every kubectl call in the lab, including the ones in resize.sh, goes to the lab cluster.
kubectl() {
  command kubectl --context "${LAB_CONTEXT}" "$@"
}

# ── Output ──────────────────────────────────────────────────────────────────────

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# ts [epoch]: RFC 3339 UTC timestamp, now or for an epoch.
ts() {
  if [ $# -gt 0 ]; then
    jq -rn --argjson e "$1" '$e | todate'
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

epoch_now() { date +%s; }

# epoch_of RFC3339: seconds since the epoch.
epoch_of() {
  printf '%s' "$1" | jq -R 'fromdateiso8601'
}

# ── Narrated steps ──────────────────────────────────────────────────────────────
# step_init TOTAL, then step "title" before each step.
# With PAUSE=1 the script waits for Enter before every step (live demo mode).

STEP_TOTAL=0
STEP_N=0

step_init() {
  STEP_TOTAL="$1"
  STEP_N=0
}

step() {
  STEP_N=$((STEP_N + 1))
  if [ "${PAUSE:-0}" = "1" ]; then
    printf '\n[Enter to continue] '
    read -r _ || true
  fi
  printf '\n==> Step %s/%s: %s\n' "${STEP_N}" "${STEP_TOTAL}" "$*"
}

# show CMD...: print the command (quoted where needed, repo paths shortened), then run it.
show() {
  local out="" a
  for a in "$@"; do
    case "${a}" in
      *[!A-Za-z0-9_./:=@%+,-]*) out="${out} '${a}'" ;;
      *) out="${out} ${a}" ;;
    esac
  done
  printf '$%s\n' "${out//${REPO_ROOT}\//}"
  "$@"
}

# ── Polling ─────────────────────────────────────────────────────────────────────
# Never sleep to "wait for" something: poll the condition with a timeout.

# poll_until TIMEOUT_SECONDS INTERVAL_SECONDS CMD...: 0 when CMD succeeds, 1 on timeout.
poll_until() {
  local timeout="$1" interval="$2" deadline
  shift 2
  deadline=$(($(epoch_now) + timeout))
  while ! "$@"; do
    [ "$(epoch_now)" -lt "${deadline}" ] || return 1
    sleep "${interval}"
  done
}

# wait_until_epoch EPOCH: block until the clock reaches EPOCH. Used for fixed
# observation windows ("3 minutes after Ready"), not for waiting on a condition.
wait_until_epoch() {
  while [ "$(epoch_now)" -lt "$1" ]; do
    sleep 1
  done
}

# ── Preconditions ───────────────────────────────────────────────────────────────

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. Install it and retry."
}

# version_ge A B: true when version A >= B (dotted numbers).
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

preflight_tools() {
  local t v
  for t in docker kind kubectl helm jq; do
    require_tool "${t}"
  done
  v="$(command kubectl version --client -o json | jq -r '.clientVersion | "\(.major).\(.minor)"' | tr -d '+')"
  version_ge "${v}" "1.32" || die "kubectl ${v} is too old; --subresource=resize needs v1.32 or later."
}

preflight_cgroup_v2() {
  local v
  v="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || true)"
  [ "${v}" = "2" ] || die "the container host uses cgroup v${v:-?}; the lab reads cpu.max and cpu.stat and needs cgroup v2."
}

preflight_host_size() {
  local cpus mem_gib
  cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
  mem_gib="$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1 / 1073741824}')"
  [ "${cpus}" -ge 4 ] || die "the container host has ${cpus} CPUs; the lab needs at least 4 (colima start --cpu 6 --memory 10)."
  [ "${mem_gib:-0}" -ge 7 ] || die "the container host has ${mem_gib:-0} GiB of memory; the lab needs at least 8 (colima start --cpu 6 --memory 10)."
}

# preflight_cluster: the cluster exists, answers, and its worker is big enough.
preflight_cluster() {
  local cpu
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
    || die "kind cluster '${CLUSTER_NAME}' not found. Run ./lab.sh up."
  kubectl get nodes >/dev/null 2>&1 || die "cannot reach the cluster (context ${LAB_CONTEXT})."
  cpu="$(kubectl get nodes -l demo/role=worker -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || true)"
  [ -n "${cpu}" ] || die "no node labeled demo/role=worker. Run ./lab.sh up."
  case "${cpu}" in
    *m) cpu=$((${cpu%m} / 1000)) ;;
  esac
  [ "${cpu}" -ge 4 ] || die "worker node has ${cpu} allocatable CPUs; the lab needs at least 4."
}

preflight() {
  preflight_tools
  preflight_cgroup_v2
  preflight_cluster
}

# ── Namespaces ──────────────────────────────────────────────────────────────────

# lab_namespace_ok NS: only lab namespaces may be deleted or recreated.
lab_namespace_ok() {
  case " ${LAB_NAMESPACES} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# ns_recreate NS: delete the namespace if it exists and wait until it is gone.
# The caller applies manifests (which create the namespace again) afterwards.
ns_recreate() {
  lab_namespace_ok "$1" || die "refusing to touch namespace '$1'."
  kubectl delete namespace "$1" --ignore-not-found --wait=true >/dev/null
}

# ── Pods ────────────────────────────────────────────────────────────────────────

# newest_pod NS SELECTOR: name of the newest Pod matching the selector.
newest_pod() {
  kubectl get pods -n "$1" -l "$2" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | tail -n1
}

_pod_exists() { [ -n "$(newest_pod "$1" "$2")" ]; }

# wait_pod NS SELECTOR [TIMEOUT]: wait until a Pod exists and is Ready; prints its name.
wait_pod_ready() {
  local ns="$1" sel="$2" timeout="${3:-420}" pod
  poll_until 120 1 _pod_exists "${ns}" "${sel}" || die "no Pod matches '${sel}' in ${ns}."
  pod="$(newest_pod "${ns}" "${sel}")"
  kubectl wait --for=condition=Ready "pod/${pod}" -n "${ns}" --timeout="${timeout}s" >/dev/null \
    || die "Pod ${pod} did not become Ready within ${timeout}s."
  printf '%s\n' "${pod}"
}

pod_created_at() { kubectl get pod "$2" -n "$1" -o jsonpath='{.metadata.creationTimestamp}'; }

pod_ready_at() {
  kubectl get pod "$2" -n "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}'
}

# container_field NS POD JSONPATH-with-NAME: spec/status of the app container, always by name.
spec_cpu() { # NS POD requests|limits
  kubectl get pod "$2" -n "$1" -o jsonpath="{.spec.containers[?(@.name==\"${APP_CONTAINER}\")].resources.$3.cpu}"
}
actual_cpu() { # NS POD requests|limits
  kubectl get pod "$2" -n "$1" -o jsonpath="{.status.containerStatuses[?(@.name==\"${APP_CONTAINER}\")].resources.$3.cpu}"
}
restart_count() {
  kubectl get pod "$2" -n "$1" -o jsonpath="{.status.containerStatuses[?(@.name==\"${APP_CONTAINER}\")].restartCount}"
}

# cgroup_file NS POD FILE: read a file from the app container's cgroup.
cgroup_file() {
  kubectl exec -n "$1" "$2" -c "${APP_CONTAINER}" -- cat "/sys/fs/cgroup/$3" 2>/dev/null
}

# cpu_stat_value NS POD KEY: one counter from cpu.stat (nr_periods, nr_throttled, throttled_usec, usage_usec).
cpu_stat_value() {
  cgroup_file "$1" "$2" cpu.stat | awk -v k="$3" '$1 == k {print $2}'
}

# spring_startup_seconds NS POD: the "Started PetClinicApplication in X seconds" value.
spring_startup_seconds() {
  kubectl logs -n "$1" "$2" -c "${APP_CONTAINER}" 2>/dev/null \
    | sed -n 's/.*Started [A-Za-z]* in \([0-9.]*\) seconds.*/\1/p' | head -n1
}

# ── Operator and VPA ────────────────────────────────────────────────────────────

ensure_operator() {
  kubectl apply -k "${REPO_ROOT}/implementation-operator" >/dev/null
  kubectl rollout status deployment/startup-boost-operator -n "${NS_OPERATOR}" --timeout=180s >/dev/null \
    || die "the operator did not become ready in ${NS_OPERATOR}."
}

ensure_vpa() {
  kubectl get deployment vpa-updater -n kube-system >/dev/null 2>&1 \
    || die "VPA is not installed. Run ./lab.sh up."
}
