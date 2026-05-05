# Implementation 3: Vertical Pod Autoscaler (In-Place Mode)

## How It Works

The Vertical Pod Autoscaler (VPA) is a Kubernetes add-on with three components:

| Component | Role |
|---|---|
| **Recommender** | Continuously reads CPU/memory metrics from `metrics-server`. Produces resource recommendations based on observed usage history. Stores history in `VPACheckpoint` objects so recommendations survive restarts. |
| **Updater** | Watches VPA objects for recommendations. When a recommendation diverges from current allocation, it attempts an in-place resize via `pods/resize`. Only evicts the pod if in-place is not possible (e.g. memory change with `RestartContainer` policy). |
| **Admission Controller** | A mutating webhook that rewrites pod resource fields on creation to match the current VPA recommendation, before the pod is scheduled. |

With `updateMode: InPlaceOrRecreate`, the Updater uses the same `pods/resize` subresource as the sidecar and operator implementations. Combined with `resizePolicy: NotRequired` on the container, the JVM is never restarted during a CPU change.

```
VPA lifecycle
────────────────────────────────────────────────────────────────
 metrics-server ──CPU/mem usage──▶ VPA Recommender
                                        │
                                        │ recommendation (target, bounds)
                                        ▼
 Pod creation ◀──resource rewrite── VPA Admission Controller
                  (if rec exists)

 Pod running ──CPU drops after JIT──▶ VPA Recommender detects change
                                        │
                                        ▼
                                   VPA Updater
                                        │ InPlaceOrRecreate
                                        ▼
                              PATCH pods/<name>/resize
                                        │
                                        ▼
                              Kubelet adjusts cgroups in-place
────────────────────────────────────────────────────────────────
```

Unlike the sidecar and operator approaches, VPA is **driven by observed metrics**, not by the Ready condition. It learns what the pod actually needs rather than relying on a predetermined steady-state CPU value.

## Design Decisions

### Why `updateMode: InPlaceOrRecreate`?

The classic VPA update modes are `Off` (recommendations only, no enforcement) and `Auto` (evict and recreate pods to apply recommendations). `InPlaceOrRecreate` is a newer mode (available since VPA 1.0, using `pods/resize` GA since K8s 1.35) that:
1. Tries an in-place resize first — no disruption, no JVM restart
2. Falls back to eviction only if in-place is not possible

For a JVM workload, eviction means a full restart cycle (~60–90s warmup again). In-place is always preferable when the policy allows it. The `restartPolicy: NotRequired` on both `cpu` and `memory` means VPA can change either resource in-place.

### Why `controlledValues: RequestsAndLimits`?

With `RequestsOnly`, VPA sets only `requests` and leaves `limits` at their original (high) values. This is suitable for cluster bin-packing but leaves the pod with unlimited burst on the node. `RequestsAndLimits` keeps `requests == limits` for the resources VPA manages, which tightens the cgroup limit to the actual recommendation.

**QoS class safety**: VPA is aware of QoS class immutability. Even with `RequestsAndLimits`, if equalising a resource would change Burstable → Guaranteed, VPA only adjusts the request and leaves the limit intact. In practice for this demo: CPU requests and limits are set equal by VPA, but memory limits stay at 512Mi while requests go to 256Mi — preserving Burstable QoS.

### Why `minAllowed.cpu: 200m` and `maxAllowed.cpu: 4000m`?

- **`minAllowed`** is the most important guard for JVM workloads. Without it, VPA's uncapped recommendation can drop to 15m CPU (the idle usage of a warmed-up JVM with no traffic). A JVM running on 15m would take minutes to respond to any real workload. `200m` is a practical floor that keeps the JVM responsive.
- **`maxAllowed`** prevents recommendation runaway if the Recommender observes an unusually CPU-intensive spike and overshoots. `4000m` is set above the node's 4-CPU capacity, so it effectively means "no upper cap within node constraints" while still preventing unbounded recommendations.

### Why `minReplicas: 1` in the update policy?

VPA's Updater, in eviction fallback mode, can evict all pods in a single-replica Deployment simultaneously, taking the service to zero availability. `minReplicas: 1` tells the Updater to always keep at least one pod running. Since in-place resize doesn't involve eviction, this guard is primarily relevant as a safety net for the eviction fallback path.

### VPA Checkpoint and warm-up period

The VPA Recommender stores its learned resource history in `VPACheckpoint` objects (`kubectl get vpacheckpoint -n <ns>`). These persist across Recommender restarts and across pod deletions. In practice:
- **First run on a fresh cluster**: Recommender has no history. It watches metrics and starts building a model. Initial recommendations appear after ~5 minutes.
- **Subsequent runs**: The Recommender loads the checkpoint and may have a recommendation within ~30 seconds of the VPA object being created.

### VPA Updater only fires when the pod is outside the recommended range

The Updater checks two conditions before resizing a pod:
1. **Range check**: is the current allocation outside `[lowerBound, upperBound]`?
2. **Age check**: is the pod old enough to touch (avoids disrupting pods that are still starting)?

If the current CPU is *within* the range, the Updater logs:
```
"Not updating a short-lived pod, request within recommended range"
```
and skips the pod entirely — even if `target` is far lower than the current value.

**Why this bites the demo**: if a VPACheckpoint exists from a previous run where petclinic burned 1500m, the Recommender factors that spike into the `upperBound` (e.g. 1600m). Since the pod's current CPU (1500m) sits inside `[200m, 1600m]`, the Updater never fires.

**Fix**: delete the checkpoint so the Recommender re-learns from current (low) usage. Once it converges to a tight `upperBound` below 1500m, the Updater triggers the in-place resize.

```bash
kubectl delete vpacheckpoint -n cpu-burst-demo --all
# Wait ~60–90s for the Recommender to rebuild the recommendation,
# then watch the resize events appear:
kubectl get events -n cpu-burst-demo --sort-by='.lastTimestamp' | grep -i resize
```

### Why the Admission Controller matters for demo sequencing

If VPA has a recommendation ready when the pod is created (e.g. from a prior checkpoint), the Admission Controller rewrites the pod's resource requests to the recommendation **before the pod is scheduled**. The pod then starts with the recommended values rather than the burst values defined in the Deployment template.

For the demo to show the full burst → resize flow, there are two options:
1. **Delete the VPACheckpoint** before applying the manifests (forces a clean recommendation cycle)
2. **Accept the admission controller behaviour** — in practice, the Admission Controller rewriting resources means VPA already "knows" this workload and immediately provisions it correctly, which is actually a more mature version of the same optimisation

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  kube-system namespace                                               │
│                                                                      │
│  ┌──────────────────┐   ┌────────────────────┐   ┌───────────────┐  │
│  │ VPA Recommender  │   │  VPA Updater        │   │ VPA Admission │  │
│  │                  │   │                    │   │ Controller    │  │
│  │ Reads metrics    │──▶│ Watches VPA object  │   │               │  │
│  │ Produces recs    │   │ Tries pods/resize   │   │ Mutates pods  │  │
│  │ Writes checkpts  │   │ Evicts as fallback  │   │ on creation   │  │
│  └──────────────────┘   └────────────────────┘   └───────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
         │ reads metrics                │ patches pods
         ▼                             ▼
┌─────────────────┐      ┌─────────────────────────────────────────┐
│ metrics-server  │      │  cpu-burst-demo namespace               │
└─────────────────┘      │                                         │
                         │  Deployment: petclinic                  │
                         │  VPA: petclinic-vpa                     │
                         │    updateMode: InPlaceOrRecreate         │
                         │    minAllowed.cpu: 200m                 │
                         │    maxAllowed.cpu: 4000m                │
                         └─────────────────────────────────────────┘
```

## Prerequisites

VPA components must be installed before applying the manifests.

```bash
# Option A: use the setup script
./scripts/setup-cluster.sh --with-vpa

# Option B: install manually
bash implementation-vpa/install-vpa.sh
```

The install script uses the Fairwinds Helm chart (`fairwinds-stable/vpa`, version `4.11.0`). This chart maps to VPA app version `1.6.0`.

> **Note on VPA chart versions**: The chart's versioning is independent from the VPA app version. Chart `4.11.0` = VPA `1.6.0`. Earlier versions of this script used `9.9.2` which does not exist — the correct chart is in the `4.x` range.

> **Note on the `in-place-or-recreate` updater flag**: This flag does **not** exist in VPA 1.6+. The in-place resize behaviour is controlled by the `updateMode: InPlaceOrRecreate` field in the VPA object, not by an updater command-line flag. What is available is `--in-place-skip-disruption-budget`, which skips PDB checks for pods where all containers have `restartPolicy: NotRequired`.

## Demo Commands

```bash
# 1. Apply the manifests
kubectl apply -k implementation-vpa/

# 2. Watch the pod start with burst CPU
kubectl get pods -n cpu-burst-demo -w

# 3. Check the VPA recommendation object
kubectl get vpa petclinic-vpa -n cpu-burst-demo \
  -o jsonpath='{.status.recommendation.containerRecommendations[0]}' \
  | python3 -m json.tool

# 4. Watch the in-place resize events
kubectl get events -n cpu-burst-demo --sort-by='.lastTimestamp' \
  | grep -E 'Resize|VPA'

# 5. Confirm no restart occurred
kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'

# 6. View the VPA checkpoint (persisted recommendation history)
kubectl get vpacheckpoint -n cpu-burst-demo
```

## Expected Events

```
ResizeStarted        pod/petclinic-xxx  Pod resize started: ...cpu:200m...
InPlaceResizedByVPA  pod/petclinic-xxx  Pod was resized in place by VPA Updater.
ResizeCompleted      pod/petclinic-xxx  Pod resize completed: ...cpu:200m...
```

`InPlaceResizedByVPA` confirms the Updater used the `pods/resize` subresource rather than evicting the pod.

## The Shrinkage Trap — The Real Risk

VPA carries the highest Shrinkage Trap risk of the three implementations, for two structural reasons:

### 1. Metric-driven, not signal-driven

The sidecar and operator wait for an explicit Ready signal — a deterministic point where the JVM is done warming up. VPA waits for CPU usage to drop below a threshold. The problem: CPU can drop temporarily during startup (e.g. between C1 and C2 compilation bursts) without the JVM being fully warm. VPA may interpret this dip as steady state and shrink CPU prematurely.

### 2. Continuous re-evaluation

VPA never stops watching. A Sunday afternoon with low traffic might produce a recommendation of 200m. Monday morning's traffic spike then finds the JVM throttled and slow to JIT-compile new code paths. The sidecar and operator fire once and stop; VPA keeps adjusting.

### Mitigations in this demo

```yaml
minAllowed:
  cpu: "200m"    # hard floor — VPA cannot go below this
```

Additional tuning recommended for production JVM workloads (add to the VPA Recommender Deployment args):

```bash
--pod-recommendation-min-cpu-millicores=200
--recommendation-lower-bound-cpu-percentile=50    # less aggressive floor
--recommendation-upper-bound-cpu-percentile=95    # use P95, not P100
--cpu-histogram-decay-half-life=12h               # slower decay = less reactivity to quiet periods
```

## Trade-offs

| | |
|---|---|
| ✅ No application changes | VPA is fully external to the workload |
| ✅ Self-tuning | Adapts to actual traffic patterns; no hardcoded steady-state CPU |
| ✅ Platform-level | One VPA stack covers all namespaces and workloads |
| ✅ Rich telemetry | `target`, `lowerBound`, `upperBound`, `uncappedTarget` per container |
| ❌ Warm-up period | First-run recommendation takes ~5 minutes on a fresh cluster |
| ❌ Shrinkage Trap risk | Continuous re-evaluation; requires careful `minAllowed` tuning |
| ❌ JVM-hostile defaults | Default decay and percentile settings are tuned for stateless HTTP services |
| ❌ Operational complexity | 3 extra components, CRDs, and a mutating webhook to manage |
| ❌ Admission Controller conflicts | VPA's webhook can conflict with other mutating webhooks (e.g. Istio sidecar injection) |

## Shrinkage Trap Risk: HIGH

Requires careful configuration of `minAllowed`, Recommender decay settings, and ideally monitoring alerts on `vpa_recommender_target_cpu_*` metrics to be production-safe for JVM workloads. Best suited for teams with a dedicated platform function who can invest in tuning and ongoing observability.
