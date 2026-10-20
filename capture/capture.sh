#!/usr/bin/env bash
# capture.sh <asset> - run the scenario an asset needs (if there is no result yet),
# then the capture command. Called by ./lab.sh capture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/capture/out"
PY="${OUT}/venv/bin/python"
RESULTS="${ROOT}/results"
mkdir -p "${OUT}"

latest() { # SCENARIO: newest results/<scenario>-<date>.json
  local f
  for f in "${RESULTS}"/*.json; do
    [ -f "${f}" ] || continue
    if [ "$(jq -r .scenario "${f}")" = "$1" ]; then echo "${f}"; fi
  done | sort | tail -n1
}

ensure() { # SCENARIO [lab.sh args...]
  local s="$1"
  shift
  if [ -z "$(latest "${s}")" ]; then
    "${ROOT}/lab.sh" "${s}" "$@"
  fi
}

need_python() {
  [ -x "${PY}" ] || { echo "error: run ./capture/setup.sh first." >&2; exit 1; }
}

need_vhs() {
  command -v vhs >/dev/null 2>&1 || { echo "error: vhs not found (brew install vhs)." >&2; exit 1; }
}

asset="${1:-}"
case "${asset}" in
  gap-chart)
    need_python
    ensure compare
    f="$(latest compare)"
    from="$(jq -r '.events.peak_pod_created' "${f}")"
    to="$(jq -rn --arg t "${from}" '($t | fromdateiso8601) + 180 | todate')"
    "${PY}" "${ROOT}/capture/grafana.py" --panel cpu --namespace cpu-burst-compare --pod 'petclinic-peak.*' \
      --from "${from}" --to "${to}" --out "${OUT}/gap-chart.png"
    ;;
  numbers)
    "${ROOT}/capture/numbers.sh" | tee "${OUT}/numbers.md"
    ;;
  demo1-compare | demo2-manual-resize | demo3-stabilization | operator-status)
    need_vhs
    (cd "${ROOT}" && vhs "capture/tapes/${asset}.tape")
    ;;
  stabilization-png)
    need_python
    ensure stabilization
    f="$(latest stabilization)"
    "${PY}" "${ROOT}/capture/grafana.py" --panel dashboard --namespace cpu-burst-stabilization --pod 'petclinic.*' \
      --results "${f}" --window runs.a_0s.window --height 1000 --out "${OUT}/stabilization-0.png"
    "${PY}" "${ROOT}/capture/grafana.py" --panel dashboard --namespace cpu-burst-stabilization --pod 'petclinic.*' \
      --results "${f}" --window runs.b_30s.window --height 1000 --out "${OUT}/stabilization-30.png"
    ;;
  jdk-8359211)
    need_python
    "${PY}" "${ROOT}/capture/web.py" --url https://bugs.openjdk.org/browse/JDK-8359211 --out "${OUT}/jdk-8359211.png"
    ;;
  *)
    echo "usage: capture.sh <gap-chart|numbers|demo1-compare|demo2-manual-resize|demo3-stabilization|operator-status|stabilization-png|jdk-8359211>" >&2
    exit 1
    ;;
esac
