# shellcheck shell=bash
# images.sh - every image the scenarios use, and how to preload them into kind
# so the demos run with no network.

LAB_IMAGES="
ghcr.io/graz-dev/spring-petclinic-jdk25:0.2.0
ghcr.io/graz-dev/startup-boost-operator:sha-84e5843
alpine/k8s:1.37.1
grafana/k6:1.8.2
"

host_platform() {
  case "$(uname -m)" in
    arm64 | aarch64) echo "linux/arm64" ;;
    *) echo "linux/amd64" ;;
  esac
}

# preload_images: pull each image once and load it into every kind node.
# Saving a single platform avoids the "content digest not found" error that
# "kind load docker-image" hits with multi-platform images.
preload_images() {
  local img platform tar
  platform="$(host_platform)"
  tar="$(mktemp)"
  for img in ${LAB_IMAGES}; do
    info "preloading ${img}"
    docker pull --quiet --platform "${platform}" "${img}" >/dev/null
    if docker save --platform "${platform}" -o "${tar}" "${img}" 2>/dev/null; then
      kind load image-archive "${tar}" --name "${CLUSTER_NAME}" >/dev/null
    else
      kind load docker-image "${img}" --name "${CLUSTER_NAME}" >/dev/null
    fi
  done
  rm -f "${tar}"
}
