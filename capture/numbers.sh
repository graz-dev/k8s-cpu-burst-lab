#!/usr/bin/env bash
# numbers.sh - every number the slides need, in one markdown table, each with its
# source. Values come from results/*.json; the startup-peak rows come from
# Prometheus (through Grafana) over the window recorded in the compare results.
# A value that was not measured yet prints as TBD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="${ROOT}/results"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:${GRAFANA_HOST_PORT:-3000}}"

latest() { # SCENARIO
  local f
  for f in "${RESULTS}"/*.json; do
    [ -f "${f}" ] || continue
    if [ "$(jq -r .scenario "${f}")" = "$1" ]; then echo "${f}"; fi
  done | sort | tail -n1
}

# row SLIDE LABEL FILE JQ_EXPR
row() {
  local v src
  if [ -z "$3" ]; then
    printf '| %s | %s | TBD | not measured yet |\n' "$1" "$2"
    return
  fi
  v="$(jq -r "($4) | if . == null then \"TBD\" else . end" "$3")"
  src="$(basename "$3") $4"
  printf '| %s | %s | %s | %s |\n' "$1" "$2" "${v}" "${src}"
}

prom_range() { # QUERY FROM_EPOCH TO_EPOCH
  curl -s -u admin:admin -G "${GRAFANA_URL}/api/datasources/proxy/uid/prometheus/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "start=$2" --data-urlencode "end=$3" --data-urlencode "step=5"
}

compare="$(latest compare)"
manual="$(latest manual-resize)"
stab="$(latest stabilization)"
jvm="$(latest jvm-cpus)"
vpa="$(latest vpa)"

echo "| Slide | Number | Value | Source |"
echo "|---|---|---|---|"

# Resource gap: the peak Pod, first 3 minutes after creation.
if [ -n "${compare}" ] && command -v curl >/dev/null; then
  created="$(jq -r '.events.peak_pod_created' "${compare}")"
  t0="$(jq -rn --arg t "${created}" '$t | fromdateiso8601')"
  q='sum(rate(container_cpu_usage_seconds_total{namespace="cpu-burst-compare",pod=~"petclinic-peak.*",container="petclinic",image!=""}[30s])) * 1000'
  all="$(prom_range "${q}" "${t0}" $((t0 + 180)) || true)"
  late="$(prom_range "${q}" $((t0 + 120)) $((t0 + 180)) || true)"
  src="Prometheus ${q} over $(basename "${compare}") peak_pod_created + 180 s"
  peak="$(printf '%s' "${all}" | jq -r '[.data.result[0].values[]?[1] | tonumber] | if length > 0 then max | floor else "TBD" end' 2>/dev/null || echo TBD)"
  dur="$(printf '%s' "${all}" | jq -r '[.data.result[0].values[]?[1] | tonumber | select(. >= 750)] | if length > 0 then length * 5 else "TBD" end' 2>/dev/null || echo TBD)"
  steady="$(printf '%s' "${late}" | jq -r '[.data.result[0].values[]?[1] | tonumber] | if length > 0 then (add / length | floor) else "TBD" end' 2>/dev/null || echo TBD)"
  printf '| Resource gap | Startup peak (millicores) | %s | %s |\n' "${peak:-TBD}" "${src}"
  printf '| Resource gap | Seconds at or above 750m (half of the 1500m request) | %s | %s |\n' "${dur:-TBD}" "${src}"
  printf '| Resource gap | Steady state, 2 to 3 minutes after creation, no load (millicores) | %s | %s |\n' "${steady:-TBD}" "${src}"
else
  printf '| Resource gap | Startup peak, peak duration, steady state | TBD | run ./lab.sh compare, monitoring up |\n'
fi
row "Resource gap" "Kubernetes version" "${compare}" '.cluster.kubernetes'
row "Resource gap" "Worker node allocatable CPU" "${compare}" '.cluster.worker_cpus'
row "Resource gap" "Worker node allocatable memory" "${compare}" '.cluster.worker_memory'

# Demo 1
for v in steady peak boost; do
  row "Demo 1" "${v}: time to Ready (s)" "${compare}" ".variants.${v}.ready_seconds"
  row "Demo 1" "${v}: Spring startup (s)" "${compare}" ".variants.${v}.spring_startup_seconds"
  row "Demo 1" "${v}: nr_throttled at Ready" "${compare}" ".variants.${v}.nr_throttled_at_ready"
  row "Demo 1" "${v}: throttled_usec at Ready" "${compare}" ".variants.${v}.throttled_usec_at_ready"
  row "Demo 1" "${v}: CPU request after hold" "${compare}" ".variants.${v}.cpu_request_after_hold"
  row "Demo 1" "${v}: restarts" "${compare}" ".variants.${v}.restart_count"
done

# Demo 2
row "Demo 2" "cpu.max before" "${manual}" '.before.cpu_max'
row "Demo 2" "cpu.max after" "${manual}" '.after.cpu_max'
row "Demo 2" "restartCount" "${manual}" '.restart_count'

# Timing
for k in a_0s b_30s; do
  row "Timing" "${k}: throttling ratio, 120 s after resize" "${stab}" ".runs.${k}.throttle.ratio_after"
  row "Timing" "${k}: k6 p50 after resize (ms)" "${stab}" ".runs.${k}.k6_window.p50_ms"
  row "Timing" "${k}: k6 p95 after resize (ms)" "${stab}" ".runs.${k}.k6_window.p95_ms"
done

# Timing / JVM
for v in default cpus1; do
  row "Timing / JVM" "${v}: CPUs detected at startup" "${jvm}" ".variants.${v}.detected_cpus_at_startup"
  row "Timing / JVM" "${v}: throttling ratio during load" "${jvm}" ".variants.${v}.throttle.ratio_during_load"
  row "Timing / JVM" "${v}: k6 p95 (ms)" "${jvm}" ".variants.${v}.k6_window.p95_ms"
done

# VPA
row "Operator / VPA" "VPA: initial CPU request after rollout" "${vpa}" '.rollout.initial_cpu_request'
row "Operator / VPA" "VPA: boost kept after rollout" "${vpa}" '.rollout.boost_kept'
