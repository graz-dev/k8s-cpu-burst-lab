# Implementation 1: Sidecar-Based Startup Resize

## How It Works

A lightweight sidecar container (`startup-resizer`) runs inside the same pod as the application. It polls the Kubernetes API every 5 seconds until the app container's Ready condition is `true`, then submits an **in-place resize patch** via the `pods/resize` subresource to shrink CPU from the burst value (`1500m`) to the steady-state value (`300m`) — without restarting the JVM.

```
Pod startup timeline
────────────────────────────────────────────────────────────────
 0s      App starts. JVM loads classes, JIT compiles hot paths.
         cpu=1500m is available — C2 compiler gets full headroom.

 ~60s    Spring context bootstraps. /actuator/health returns UP.
         readinessProbe passes → container.ready = true.

 ~60s+Δ  Sidecar detects ready=true. Patches pod via pods/resize.

 ~60s+2Δ Kubelet adjusts cgroup CPU quota in-place → cpu=300m.
         JVM keeps running. restartCount stays 0.

 ∞       Sidecar enters sleep infinity. Pod idles at 300m.
────────────────────────────────────────────────────────────────
```

## Architecture

```
┌─────────────── Pod ──────────────────────────────────────────┐
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ container: petclinic                                  │  │
│  │   image: ghcr.io/graz-dev/spring-petclinic-jdk25       │  │
│  │   cpu: 1500m (burst) → 300m (steady-state, in-place)  │  │
│  │   resizePolicy: cpu=NotRequired                       │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ container: startup-resizer (sidecar)                  │  │
│  │   image: bitnami/kubectl                              │  │
│  │   1. polls K8s API for container.ready=true           │  │
│  │   2. kubectl patch --subresource=resize               │  │
│  │   3. waits for kubelet to confirm (status.resize="")  │  │
│  │   4. exec sleep infinity                              │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
                 │ PATCH pods/resize (K8s API)
                 ▼
        ┌──────────────┐   cgroup update   ┌──────────────┐
        │  API Server  │ ─────────────────▶│   Kubelet    │
        └──────────────┘                   └──────────────┘
```

## Design Decisions

### Why `bitnami/kubectl` for the sidecar image?

The sidecar needs to call the Kubernetes API to (a) check the pod's Ready condition and (b) submit the resize patch. `bitnami/kubectl` is the smallest image that bundles a recent-enough `kubectl` to support `--subresource=resize` (introduced in kubectl 1.33).

Alternatives considered:
- **Custom shell script + `curl`**: requires crafting raw HTTPS requests with Bearer token, parsing JSON responses manually — brittle and harder to maintain.
- **A small Go binary**: correct approach for production, but adds a build step to the demo; this is a talk demo, not production code.
- **`alpine/k8s`**: includes many extra tools; heavier than needed.

### Why `command: ["/bin/sh", "/scripts/resize.sh"]`?

`bitnami/kubectl` sets `ENTRYPOINT=["kubectl"]` in its image. If you only specify `args:`, the entrypoint wraps them as `kubectl <args>`. To run a shell script, both `command` (which overrides `ENTRYPOINT`) and the script path must be specified. This is the single most common source of `CrashLoopBackOff` when using this image as a sidecar.

### Why poll the Kubernetes API for readiness instead of the HTTP endpoint?

The sidecar shares the pod network namespace, so it can reach `localhost:8080` directly. However, checking the Kubernetes Ready condition (rather than the raw HTTP endpoint) is more semantically correct: the Ready condition integrates all probes (readiness probe, startup probe, initialDelaySeconds). A direct HTTP 200 from `/actuator/health` does not mean the pod is Ready in Kubernetes terms — the kubelet's probe machinery may not have caught up yet.

### Why CPU-only patch?

```json
{
  "spec": {
    "containers": [{
      "name": "petclinic",
      "resources": {
        "requests": { "cpu": "300m" },
        "limits":   { "cpu": "300m" }
      }
    }]
  }
}
```

The pod starts as **Burstable** QoS: `cpu requests = cpu limits = 1500m`, `memory requests (512Mi) < memory limits (1Gi)`. Kubernetes enforces that a resize cannot change the pod's QoS class. Patching memory requests and limits to equal values would flip QoS to Guaranteed — and K8s rejects it. Patching only CPU leaves memory unchanged, QoS stays Burstable, and the resize succeeds.

### Why `--subresource=resize` instead of a direct pod PATCH?

In Kubernetes 1.33+ (when in-place resize became GA), the API server's immutability validator blocks direct PATCH on pod resource fields. Even with `InPlacePodVerticalScaling=true` and `resizePolicy: NotRequired` set, a direct `kubectl patch pod` returns:

```
The Pod "petclinic-xxx" is invalid: spec.containers[0].resources: ...
pod updates may not change fields other than spec.containers[*].image
```

The dedicated `pods/resize` subresource exists precisely to bypass this check for legitimate resize operations. It's a separate RBAC surface:

```yaml
- apiGroups: [""]
  resources: ["pods/resize"]
  verbs: ["get", "patch", "update"]
```

Note that `get` is required because `kubectl patch` fetches the current state before applying the patch.

## Key Manifest Fields

### `resizePolicy` — prevents JVM restart

```yaml
resizePolicy:
  - resourceName: cpu
    restartPolicy: NotRequired    # ← critical
  - resourceName: memory
    restartPolicy: NotRequired
```

Without this, kubelet restarts the container on any resource change, defeating the entire approach.

### Downward API — pod self-awareness

```yaml
env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  - name: POD_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
```

The sidecar script uses these to construct `kubectl patch pod ${POD_NAME} -n ${POD_NAMESPACE}`. Without them, the script has no way to know which pod it is running in.

## RBAC

The sidecar's `ServiceAccount` (`startup-resizer`) needs:
- `pods: [get, list, watch]` — to check the container's Ready condition
- `pods/resize: [get, patch, update]` — GET is required because `kubectl patch` reads before writing

No cluster-scoped permissions are needed — all resources are namespaced to `cpu-burst-demo`.

## Demo Commands

```bash
# Apply all manifests
kubectl apply -k implementation-sidecar/

# Follow the sidecar log in real-time
kubectl logs -n cpu-burst-demo \
  -l app.kubernetes.io/name=petclinic \
  -c startup-resizer -f

# Watch CPU allocation change
watch -n2 "kubectl get pod -n cpu-burst-demo \
  -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{.items[0].status.containerStatuses[0].allocatedResources}'"

# Confirm resize completed with 0 restarts
kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{range .items[0].status.containerStatuses[*]}{.name}: restarts={.restartCount}, cpu={.allocatedResources.cpu}{"\n"}{end}'
```

## Trade-offs

| | |
|---|---|
| ✅ Zero additional infra | No operator, no CRD, no controller |
| ✅ Deterministic trigger | Fires within seconds of the readiness probe passing |
| ✅ Self-contained | The resizing logic travels with the pod |
| ✅ No Shrinkage Trap | Fires once, then sleeps forever; cannot re-trigger |
| ❌ Sidecar resource overhead | Adds a container (albeit tiny: `cpu 10m / 50m, mem 32Mi / 64Mi`) per pod |
| ❌ `bitnami/kubectl` must be accessible | In air-gapped clusters, the image must be mirrored |
| ❌ Scales with pods, not with services | 500 pods → 500 sidecars; the operator approach avoids this |

## Shrinkage Trap Risk: NONE

The sidecar fires exactly once. After submitting the resize and confirming `status.resize` is empty (meaning the kubelet applied it), the script calls `exec sleep infinity` and never touches the API again. A pod restart resets the sidecar too — the new pod starts with burst CPU again, which is the correct behaviour for a new JVM instance.
