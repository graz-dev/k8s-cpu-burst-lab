# Implementation 2: Polling-Loop Controller

## How It Works

A separate `Deployment` runs a shell polling loop (`controller.sh`) inside a `bitnami/kubectl` container. Every 10 seconds it lists all pods labelled `startup-boost=enabled` in the `cpu-burst-demo` namespace, checks each pod's Ready condition, and for any pod that is Ready but not yet annotated as resized, submits an in-place resize patch via the `pods/resize` subresource. After a successful resize, the pod is annotated with `startup-boost.io/resized=true` — the **Shrinkage Trap guard** that prevents re-triggering on the same pod instance.

```
Pod startup timeline
────────────────────────────────────────────────────────────────
 0s      petclinic pod created with cpu=1500m.
         Controller starts polling (separate Deployment).

 ~60s    readinessProbe passes → Pod.status.conditions[Ready]=True.

 ≤70s    Controller's next 10s poll fires. Ready=True, not yet
         annotated. Resize patch submitted via pods/resize.

 ≤70s+Δ  Kubelet applies cgroup change. cpu=300m.
         Pod annotated: startup-boost.io/resized=true.

 ∞       Controller keeps polling. Annotation guard prevents
         re-triggering. restartCount stays 0.
────────────────────────────────────────────────────────────────
```

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Namespace: cpu-burst-demo                                   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Deployment: petclinic                                │   │
│  │   label: startup-boost=enabled                      │   │
│  │   cpu: 1500m (burst) → 300m (in-place, via controller) │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │ Pod.status.conditions[Ready]=True │
│                           ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Deployment: startup-boost-controller                 │   │
│  │   image: bitnami/kubectl                             │   │
│  │   script: /hooks/controller.sh (polling loop)        │   │
│  │                                                      │   │
│  │   Every 10s:                                         │   │
│  │     list pods{startup-boost=enabled}                 │   │
│  │     for each pod:                                    │   │
│  │       skip if Ready=False                           │   │
│  │       skip if annotation resized=true               │   │
│  │       patch pods/resize → cpu=300m                  │   │
│  │       annotate pod with resized=true                │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Design Decisions

### Why not shell-operator (flant/shell-operator)?

This implementation was originally built with [shell-operator](https://github.com/flant/shell-operator) v1.4.10. It was replaced with a `bitnami/kubectl` polling loop for two concrete reasons discovered during testing:

1. **kubectl version too old**: shell-operator v1.4.10 bundles kubectl 1.27. The `--subresource=resize` flag was added in kubectl 1.35. Every resize attempt failed with:
   ```
   error: invalid subresource value: resize. Must be one of [status scale]
   ```

2. **No curl**: the workaround would be to call the Kubernetes API directly via HTTP. shell-operator's base image (`flant/shell-operator:v1.4.10`) does not include `curl`. It includes a BusyBox `wget`, but BusyBox wget only supports GET and POST — not the PATCH method required for pod resize.

The result was an operator with no viable path to call the resize API. Rather than building a custom image, we replaced the entire approach with `bitnami/kubectl`, which ships a recent kubectl and is explicitly designed for this use case.

### Why a polling loop instead of a proper watch/event-driven controller?

A production-grade Kubernetes controller uses `client-go`'s informer + work queue to watch objects and react to changes without polling. For a talk demo, the overhead of a full Go binary is unnecessary. The polling loop is:
- Readable — the entire logic fits in ~50 lines of shell
- Transparent — the loop steps are visible in the controller logs
- Correct — the 10-second interval adds at most 10s latency to the resize trigger, which is acceptable for a startup event

A proper production implementation would use a CRD-based operator (e.g. with operator-sdk or kubebuilder) that watches pod events rather than polling.

### Why the `startup-boost=enabled` label opt-in?

The controller only processes pods with this label. This is intentional:
- It avoids inadvertently resizing pods that should not be resized (e.g. infra components in the same namespace)
- It makes the mechanism explicit in the workload's spec — a reviewer can see it's opted in
- Adding a new workload to the pattern requires only a single label, no RBAC changes or sidecar injection

### Why annotate the pod after resize?

Without an annotation guard, every controller poll cycle after the resize would attempt to patch the pod again. This would not fail (the `pods/resize` subresource is idempotent for the same values), but it would pollute the API server audit log and burn unnecessary CPU on the controller. The annotation creates a durable record of the resize that survives controller restarts and pod moves.

The annotations also serve as an audit trail for debugging:

```
startup-boost.io/resized=true
startup-boost.io/resized-at=2026-05-05T07:30:00Z
startup-boost.io/steady-cpu=300m
```

### Why CPU-only patch?

See the [sidecar README](../implementation-sidecar/README.md#why-cpu-only-patch) for the full explanation. Short version: patching memory alongside CPU would change the pod's QoS class from Burstable to Guaranteed, which Kubernetes rejects at resize time.

## The Shrinkage Trap Guard

Without a guard, the controller would re-trigger every 10 seconds after the first resize:

```
resize fired → pod spec changes → next poll → Ready=True, not annotated yet (race) → resize fired again → ...
```

Three independent guards break this:
1. **Annotation check**: `startup-boost.io/resized=true` — set immediately after a successful patch. Subsequent polls skip this pod unconditionally.
2. **In-flight check**: if `pod.status.resize` is non-empty (kubelet is still processing the resize), the loop skips this pod for the current cycle to avoid concurrent overlapping patches.
3. **Restart semantics**: if the pod restarts, its annotations are lost — but it also starts fresh with burst CPU from the Deployment template, so the controller correctly triggers a new resize for the new pod instance.

## RBAC

The controller's `ServiceAccount` (`startup-boost-controller`) needs:
- `pods: [get, list, watch]` — to list pods and read Ready conditions
- `pods: [patch]` — to write the `startup-boost.io/*` annotations
- `pods/resize: [get, patch, update]` — GET is required because kubectl reads before patching

All permissions are scoped to the `cpu-burst-demo` namespace via a `Role` (not `ClusterRole`).

## Demo Commands

```bash
# Apply all manifests
kubectl apply -k implementation-deployment/

# Watch pod startup
kubectl get pods -n cpu-burst-demo -w

# Follow the controller log (see the poll cycle and resize trigger)
kubectl logs -n cpu-burst-demo \
  -l app.kubernetes.io/name=startup-boost-controller -f

# Watch CPU allocation drop in real-time
watch -n2 "kubectl get pod -n cpu-burst-demo \
  -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{.items[0].status.containerStatuses[0].allocatedResources}'"

# Confirm annotation was set (the Shrinkage Trap guard)
kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{.items[0].metadata.annotations}' | python3 -m json.tool

# Confirm 0 restarts
kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'
```

## Scaling the Pattern

Because the controller is external to the application pod, one controller instance handles **all** pods with the `startup-boost=enabled` label. Adding a new workload is a single label:

```yaml
# In the Deployment's pod template metadata:
labels:
  startup-boost: "enabled"
```

No sidecar to inject, no ServiceAccount per workload, no change to the controller.

## Trade-offs

| | |
|---|---|
| ✅ One controller, many workloads | Label-based opt-in — no per-pod sidecar |
| ✅ Deterministic trigger | Fires within one poll interval of the Ready transition |
| ✅ Durable guard | Annotation prevents re-triggering across controller restarts |
| ✅ Audit trail | Annotations record when, what, and to what the pod was resized |
| ❌ Extra Deployment | One more thing to deploy, monitor, and RBAC |
| ❌ Polling overhead | 10s interval means up to 10s extra latency vs. the sidecar |
| ❌ Shell operator limitations | Shell scripts lack the type safety and leader election of a proper Go operator |

## Shrinkage Trap Risk: LOW

The annotation guard makes re-triggering impossible for the lifetime of a given pod instance. The only window between Ready transition and annotation application (~1 RBAC round-trip) is covered by the in-flight check (`status.resize != ""`). Risk resets on pod restart, which is correct — a new JVM instance needs burst CPU.
