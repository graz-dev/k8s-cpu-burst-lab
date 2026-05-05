# Demo Lab — Detailed Documentation

> **Talk**: "Stop Overprovisioning for Application Startup"
> **Topic**: Kubernetes In-Place Pod Vertical Scaling (KEP-1287, GA in v1.33)
> **Goal**: Show four concrete ways to give a JVM its CPU burst at startup, then reclaim it without restarting the container.

---

## Table of Contents

1. [Background — Why This Demo Exists](#1-background)
2. [Prerequisites](#2-prerequisites)
3. [Build the Application Image](#3-build-the-application-image)
4. [Create the Cluster](#4-create-the-cluster)
5. [Implementation 1 — Sidecar](#5-implementation-1--sidecar)
6. [Implementation 2 — Deployment](#6-implementation-2--deployment)
7. [Implementation 3 — VPA](#7-implementation-3--vpa)
8. [Implementation 4 — Operator](#8-implementation-4--operator)
9. [Switching Between Implementations](#9-switching-between-implementations)
10. [Observability Cheat Sheet](#10-observability-cheat-sheet)
11. [Troubleshooting](#11-troubleshooting)
12. [Key API Concepts](#12-key-api-concepts)
13. [Teardown](#13-teardown)

---

## 1. Background

### The JVM Startup Burst Problem

Modern JVMs do intensive work at startup that they never repeat at steady state:
- **Class loading and bytecode verification** — every `.class` file in the classpath
- **JIT compilation** — the C1 (client) compiler fires immediately, C2 (server) compiles hot methods after profiling
- **GC heap initialization** — G1GC pre-allocates regions and starts background threads
- **Spring context bootstrap** — bean instantiation, AOP proxy generation, autoconfiguration

This creates a sharp, short-lived CPU spike (the **Startup Burst**) followed by a long steady state where the original allocation sits mostly idle:

```
CPU usage
│
1500m ┤   ████
      │   ████   JIT / C2 warmup (class loading + hot-path compilation)
 800m ┤   ████
      │   ████  ╲
 300m ┤   ████   ╲___________________________________  Steady-state
      │   ████
      └──────────────────────────────────────────────── Time
         0s  30s  60s  90s  120s
         │← Burst window (~60–90s) →│← Steady state ─────────────────
```

### The Traditional Options (and Why They Fail)

| Option | What You Lose |
|---|---|
| **Overprovision** — set requests to burst peak | 80–90 % of CPU allocation sits idle at steady state; inflates cluster cost and degrades bin-packing |
| **Underprovision** — set requests to steady state | JVM startup is throttled, pod takes 2–5× longer to become ready; SLO violations during rollouts and restarts |
| **Startup hooks / pre-warm** | Application-layer complexity; doesn't change how the scheduler sees the pod |
| **HPA scale-up pre-warm** | Doesn't help a single new replica; adds latency |

### The In-Place Resize Solution

Kubernetes In-Place Pod Vertical Scaling (KEP-1287, **GA in v1.33**) lets you change a running pod's `resources.requests` and `resources.limits` **without restarting the container**. The kubelet updates the cgroup limits on the running process.

The pattern:
1. Pod starts with **burst resources** (e.g. `cpu: 1500m`)
2. JVM warms up — JIT compiles hot paths, Spring context initialises
3. Readiness probe passes — something detects the pod is Ready
4. That "something" patches the pod spec via the `pods/resize` API subresource
5. Kubelet adjusts cgroups **in-place** — no container restart
6. Cluster gets back the excess CPU; JVM keeps running

---

## 2. Prerequisites

### Tools

| Tool | Minimum Version | Installation |
|---|---|---|
| Docker | 27.x | `brew install --cask docker` (macOS) |
| kind | 0.27.x | `brew install kind` |
| kubectl | 1.35 | `brew install kubectl` |
| helm | 3.17 | `brew install helm` |

> **macOS without Docker Desktop**: [Colima](https://github.com/abiosoft/colima) is a lightweight alternative.
> ```bash
> brew install colima
> colima start --cpu 4 --memory 8
> ```
> Then install Docker CLI: `brew install docker`

### Hardware

The demo cluster uses a single worker node. The Spring Petclinic app needs up to 1500m CPU and 512Mi memory during startup.

| Resource | Minimum | Recommended |
|---|---|---|
| CPU cores | 4 | 6 |
| RAM | 8 GB | 12 GB |
| Disk | 5 GB free | 10 GB free |

---

## 3. Application Image

The demo uses [spring-petclinic-jdk25](https://github.com/graz-dev/spring-petclinic-jdk25) — Spring Boot 3 on JDK 25 with G1GC and Spring Boot Actuator health endpoints. The image is published publicly on GHCR:

```
ghcr.io/graz-dev/spring-petclinic-jdk25:latest
```

kind nodes have internet access, so the image is pulled automatically when you apply the manifests — no `docker build` or `kind load` step is needed. The first `kubectl apply` on a fresh cluster will take ~1–2 minutes while the image is pulled to the worker node.

---

## 4. Create the Cluster

```bash
# 2-node kind cluster: InPlacePodVerticalScaling + Grafana auto-exposed
./scripts/setup-cluster.sh

# Include VPA components:
./scripts/setup-cluster.sh --with-vpa

# Include Grafana + Prometheus (recommended for live demos):
./scripts/setup-cluster.sh --with-monitoring

# All together:
./scripts/setup-cluster.sh --with-vpa --with-monitoring
```

After setup, the cluster looks like:

```
kind cluster: cpu-burst-lab  (Kubernetes v1.35.1)
├── control-plane  (kube-system + monitoring namespace)
│   └── port 30300 → localhost:3000  (Grafana, no port-forward needed)
└── worker         (labelled demo/role=worker)
                   └── cpu-burst-demo namespace (demo pods)
```

> **Namespace isolation**: `monitoring` is independent of `cpu-burst-demo`. Deleting the demo namespace between implementation runs leaves Grafana, Prometheus, and all their data untouched — the dashboard stays live throughout the session.

### Verify

```bash
kubectl get nodes
# NAME                          STATUS   ROLES           AGE
# cpu-burst-lab-control-plane   Ready    control-plane   2m
# cpu-burst-lab-worker          Ready    <none>          2m

kubectl get nodes cpu-burst-lab-worker --show-labels | grep demo/role
# demo/role=worker
```

### Grafana

If you used `--with-monitoring`, Grafana is immediately available at **http://localhost:3000** (admin / admin) — no port-forward required. The "CPU Burst Lab — Startup Resize" dashboard is pre-provisioned and auto-refreshes every 5 seconds.

The NodePort mapping works because `kind-config.yaml` binds `containerPort 30300` on the control-plane node to `hostPort 3000` on your machine. kube-proxy routes traffic from any node's port 30300 to the Grafana pod, wherever it is scheduled.

---

## 5. Implementation 1 — Sidecar

### What it does

A lightweight sidecar container (`startup-resizer`) runs inside the same pod as the application. It polls the Kubernetes API for the Ready condition on the app container, and once the condition is `true`, submits an in-place resize patch via the `pods/resize` subresource.

### Apply

```bash
kubectl apply -k implementation-sidecar/
```

### Expected terminal output

```bash
kubectl logs -n cpu-burst-demo \
  -l app.kubernetes.io/name=petclinic \
  -c startup-resizer -f
```

```
[resizer] Sidecar started for pod petclinic-xxx-yyy in ns cpu-burst-demo
[resizer] Will downscale 'petclinic' to cpu=300m, memory=512Mi
[resizer] Polling kubectl for pod Ready condition every 5s...
[resizer] Not ready yet (0s elapsed). Retrying in 5s...
[resizer] Not ready yet (5s elapsed). Retrying in 5s...
...                                          ← ~60–90 s of JVM warmup
[resizer] Container 'petclinic' is Ready. Initiating in-place downscale...
pod/petclinic-xxx-yyy patched
[resizer] ✅  Resize patch accepted.
[resizer] Waiting for kubelet to apply the resize...
[resizer] resize= allocatedCPU=300m
[resizer] ✅  In-place downscale complete. Pod cpu is now 300m.
[resizer] Sidecar work done — entering idle mode.
```

### Confirm the resize (no restart)

```bash
POD=$(kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic -o name | head -1)

kubectl get $POD -n cpu-burst-demo \
  -o jsonpath='spec_cpu={.spec.containers[0].resources.requests.cpu}  allocated_cpu={.status.containerStatuses[0].allocatedResources.cpu}  restarts={.status.containerStatuses[0].restartCount}{"\n"}'

# Expected:
# spec_cpu=300m  allocated_cpu=300m  restarts=0
```

### What success looks like

| Field | Before resize | After resize |
|---|---|---|
| `spec.containers[0].resources.requests.cpu` | `1500m` | `300m` |
| `status.containerStatuses[0].allocatedResources.cpu` | `1500m` | `300m` |
| `status.resize` | (empty) | (empty — means complete) |
| `status.containerStatuses[0].restartCount` | `0` | `0` |

---

## 6. Implementation 2 — Deployment

### What it does

A separate controller `Deployment` runs `bitnami/kubectl` and executes a polling loop every 10 seconds. It lists all pods labelled `startup-boost=enabled`, checks each one's Ready condition, and for any pod that is Ready but not yet annotated as resized, submits the in-place resize patch and adds `startup-boost.io/resized=true` to the pod's annotations.

### Apply

```bash
# Clean up any previous implementation first
kubectl delete namespace cpu-burst-demo --ignore-not-found

kubectl apply -k implementation-deployment/
```

### Watch the controller

```bash
kubectl logs -n cpu-burst-demo \
  -l app.kubernetes.io/name=startup-boost-operator -f
```

```
[operator] Controller started. Polling every 10s.
[operator] Target: pods{startup-boost=enabled} in ns cpu-burst-demo
[operator] Steady-state: cpu=300m memory=512Mi
[operator] petclinic-xxx-yyy: resize in progress (), skipping.    ← first polls while app starts
...
[operator] petclinic-xxx-yyy: Ready=True, not yet resized. Triggering downscale...
pod/petclinic-xxx-yyy patched
[operator] petclinic-xxx-yyy: resize patch accepted.
pod/petclinic-xxx-yyy annotated
[operator] petclinic-xxx-yyy: annotated. Will run at 300m CPU.
```

### Confirm the annotation (Shrinkage Trap guard)

```bash
kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{.items[0].metadata.annotations}' | python3 -m json.tool

# Expected annotations:
# {
#   "startup-boost.io/resized": "true",
#   "startup-boost.io/resized-at": "2026-05-05T07:30:00Z",
#   "startup-boost.io/steady-cpu": "300m"
# }
```

### What success looks like

Same fields as the sidecar table above, plus:

| Annotation | Value |
|---|---|
| `startup-boost.io/resized` | `true` |
| `startup-boost.io/resized-at` | ISO-8601 timestamp |
| `startup-boost.io/steady-cpu` | `300m` |

---

## 7. Implementation 3 — VPA

### What it does

The Vertical Pod Autoscaler adds three components to the cluster: a Recommender (observes metrics, produces resource recommendations), an Updater (applies recommendations either in-place or via eviction), and an Admission Controller (rewrites pod resources on creation).

With `updateMode: InPlaceOrRecreate`, the Updater first attempts an in-place resize via the `pods/resize` subresource. It only falls back to eviction if in-place is not possible (e.g. a memory change with `restartPolicy: RestartContainer`).

### Prerequisites

VPA must be installed before applying the manifests. If you ran `setup-cluster.sh --with-vpa`, skip this step.

```bash
bash implementation-vpa/install-vpa.sh
```

### Apply

```bash
# Clean up any previous implementation first
kubectl delete namespace cpu-burst-demo --ignore-not-found

kubectl apply -k implementation-vpa/
```

### Watch the VPA recommendation develop

```bash
# VPA needs a few minutes of metrics history on a fresh cluster.
# If VPA has seen petclinic before (e.g. from a previous run), it
# uses checkpointed history and may have a recommendation immediately.
kubectl get vpa petclinic-vpa -n cpu-burst-demo \
  -o jsonpath='{.status.recommendation}' | python3 -m json.tool
```

```json
{
  "containerRecommendations": [
    {
      "containerName": "petclinic",
      "lowerBound":     { "cpu": "200m", "memory": "256Mi" },
      "target":         { "cpu": "200m", "memory": "256Mi" },
      "uncappedTarget": { "cpu": "15m",  "memory": "100Mi" },
      "upperBound":     { "cpu": "200m", "memory": "256Mi" }
    }
  ]
}
```

> `uncappedTarget` reflects actual observed usage. `target` is clamped to `minAllowed` (200m CPU, 256Mi memory).

### Watch the in-place resize event

```bash
kubectl get events -n cpu-burst-demo --sort-by='.lastTimestamp'
```

```
ResizeStarted        pod/petclinic-xxx  Pod resize started: ...cpu:200m...
InPlaceResizedByVPA  pod/petclinic-xxx  Pod was resized in place by VPA Updater.
ResizeCompleted      pod/petclinic-xxx  Pod resize completed: ...cpu:200m...
```

The `InPlaceResizedByVPA` event confirms the Updater used the `pods/resize` subresource rather than evicting and recreating the pod.

### What success looks like

| Field | After VPA resize |
|---|---|
| `spec.containers[0].resources.requests.cpu` | `200m` (VPA recommendation) |
| `spec.containers[0].resources.limits.cpu` | `200m` |
| `spec.containers[0].resources.requests.memory` | `256Mi` |
| `spec.containers[0].resources.limits.memory` | `512Mi` (unchanged — QoS guard) |
| `status.containerStatuses[0].restartCount` | `0` |
| Event | `InPlaceResizedByVPA` |

> **Why did memory limits stay at 512Mi?** If VPA set `memory limits = memory requests = 256Mi`, both CPU and memory would be `requests == limits`, flipping the pod's QoS class from **Burstable** to **Guaranteed**. Kubernetes rejects any resize that changes QoS class. VPA is aware of this and only adjusts the memory request, leaving the limit intact.

---

## 8. Implementation 4 — Operator

### What it does

This implementation builds a purpose-built Kubernetes controller written in Go using [controller-runtime](https://github.com/kubernetes-sigs/controller-runtime) (the same framework that backs kubebuilder and Operator SDK). It extends the Kubernetes API with a `StartupBoostPolicy` custom resource.

The key difference from all previous implementations: it is **event-driven, not polling-based**. The controller registers a `Watches` hook on pod events. When any pod in the namespace transitions to Ready, `mapPodToPolicy` translates the pod event into a reconcile request for the matching policy. The resize fires within milliseconds — no 5-second or 10-second lag.

| Property | Deployment controller (impl 2) | Operator (impl 4) |
|---|---|---|
| Loop type | Poll every 10s | Event-driven (pod watch) |
| Resize lag | Up to 10s | < 1s |
| User-facing API | Pod annotation | `StartupBoostPolicy` CRD |
| Lifecycle visibility | Pod annotation only | `kubectl get sbp` shows per-pod phase |
| Language | Bash + kubectl | Go + controller-runtime |

### Prerequisites

- `docker` available on the host (needed to build the operator image)
- The kind cluster must be running

### The CRD — `StartupBoostPolicy`

This implementation registers a new Kubernetes resource kind in the cluster:

```bash
kubectl get crd startupboostpolicies.startup.boost.io
# NAME                                       CREATED AT
# startupboostpolicies.startup.boost.io      2026-05-05T10:...
```

Short name `sbp`. The policy object you apply per workload looks like this:

```yaml
apiVersion: startup.boost.io/v1alpha1
kind: StartupBoostPolicy
metadata:
  name: petclinic-boost
  namespace: cpu-burst-demo
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: petclinic   # which pods to manage
  containers:
    - name: petclinic
      steadyCPU: "300m"                   # target CPU after startup burst
  stabilizationSeconds: 0                 # wait N seconds after Ready before resizing
```

The controller watches for pods matching `selector` in the same namespace. As soon as a pod's `Ready` condition becomes `True`, the controller patches it via `pods/resize` to `steadyCPU` and writes the result back to the policy's `.status.boostedPods`.

### Apply

The operator image is published to GHCR by CI — no local Docker build needed.

```bash
# Clean up any previous implementation first
kubectl delete namespace cpu-burst-demo --ignore-not-found

cd implementation-operator

# Register the CRD, wait for the API server to accept it, then apply everything
make deploy
```

Which expands to:

```bash
kubectl apply -f config/namespace.yaml
kubectl apply -f config/crd/startup.boost.io_startupboostpolicies.yaml
kubectl wait --for=condition=Established \
  crd/startupboostpolicies.startup.boost.io --timeout=30s
kubectl apply -k .   # pulls ghcr.io/graz-dev/startup-boost-operator:latest
```

> **Why the two-step CRD apply?** The CRD must be registered (condition `Established`) before you can create instances of it. Applying the full kustomization in one shot errors with `no matches for kind "StartupBoostPolicy"` because the API server hasn't registered the new type yet. `make deploy` handles this automatically.

### Verify the CRD and policy are registered

```bash
kubectl get crd startupboostpolicies.startup.boost.io
kubectl get sbp -n cpu-burst-demo
# NAME              SELECTOR                                  STEADYCPU   AGE
# petclinic-boost   {"app.kubernetes.io/name":"petclinic"}    300m        5s
```

### Watch the operator logs

```bash
kubectl logs -n cpu-burst-demo \
  -l app.kubernetes.io/name=startup-boost-operator -f
```

Expected output:

```
INFO  Starting EventSource  source="kind source: *v1alpha1.StartupBoostPolicy"
INFO  Starting EventSource  source="kind source: *v1.Pod"
INFO  Starting Controller
INFO  Starting workers
INFO  Pod is Ready — applying in-place resize  pod=petclinic-xxx-yyy
INFO  Resize complete  pod=petclinic-xxx-yyy  steadyCPU=300m
```

### Watch the CRD status

```bash
# Per-pod phase — updates in real-time as the controller progresses
kubectl get sbp petclinic-boost -n cpu-burst-demo -w

# Detailed view with conditions and timestamps
kubectl describe sbp petclinic-boost -n cpu-burst-demo
```

Expected `describe` status section:

```yaml
Status:
  Boosted Pods:
    Name:        petclinic-xxx-yyy
    Phase:       Steady
    Resized At:  2026-05-05T10:47:44Z
    Steady CPU:  300m
  Conditions:
    Type:    Ready
    Status:  True
    Reason:  Reconciled
    Message: Managing 1 pod(s)
```

The pod goes through phases: `Burst` (starting up) → `Ready` (readiness probe passed, resize imminent) → `Steady` (resize accepted by kubelet).

### Confirm the resize (no restart)

```bash
POD=$(kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic -o name | head -1)

kubectl get $POD -n cpu-burst-demo \
  -o jsonpath='spec_cpu={.spec.containers[0].resources.requests.cpu}  allocated_cpu={.status.containerStatuses[0].allocatedResources.cpu}  restarts={.status.containerStatuses[0].restartCount}{"\n"}'

# Expected:
# spec_cpu=300m  allocated_cpu=300m  restarts=0
```

### What success looks like

| Field | Before resize | After resize |
|---|---|---|
| `spec.containers[0].resources.requests.cpu` | `1500m` | `300m` |
| `status.containerStatuses[0].allocatedResources.cpu` | `1500m` | `300m` |
| `metadata.annotations[startup.boost.io/resized]` | (absent) | `true` |
| `status.containerStatuses[0].restartCount` | `0` | `0` |
| `kubectl get sbp` Phase | `Burst` | `Steady` |

### Cleanup

```bash
# From implementation-operator/ directory
make undeploy

# Or from the repo root
kubectl delete namespace cpu-burst-demo
kubectl delete crd startupboostpolicies.startup.boost.io
```

---

## 9. Switching Between Implementations

Each implementation uses the same `cpu-burst-demo` namespace. Deleting it between runs gives a clean slate without touching anything outside it.

```bash
# Tear down the current implementation
kubectl delete namespace cpu-burst-demo

# Apply the next one
kubectl apply -k implementation-sidecar/    # or deployment / vpa
# For the CRD operator (requires docker build):
# cd implementation-operator && make deploy
```

**What survives the namespace delete:**
- `monitoring` namespace — Grafana, Prometheus, and their scraped data stay up
- `kube-system` — VPA components (Recommender, Updater, Admission Controller) stay up
- The Grafana dashboard at **http://localhost:3000** remains live and will immediately start showing data for the next implementation once its pod starts

**What resets:**
- `cpu-burst-demo` namespace and everything in it (pods, RBAC, ConfigMaps)
- VPA `VPACheckpoint` objects in `cpu-burst-demo` (deleted with the namespace) — VPA re-learns from scratch for the next run, which avoids the "upperBound too high" issue

---

## 10. Observability Cheat Sheet

### Grafana dashboard

Open **http://localhost:3000** (admin / admin) — available immediately after `./scripts/setup-cluster.sh --with-monitoring` with no port-forward.

Dashboard: **CPU Burst Lab — Startup Resize**
- Top panel: CPU usage (blue), requests (orange dashed), limits (red dashed) in millicores — auto-refreshes every 5s
- Bottom row: current CPU requests, current CPU limits, container restart count (green = 0, red = any restart)

The dramatic drop from 1500m to 300m (sidecar/operator) or 200m (VPA) is the centrepiece of the demo.

### One-liner: current CPU allocation vs. spec

```bash
POD=$(kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic -o name | head -1)

kubectl get $POD -n cpu-burst-demo -o jsonpath='
spec_cpu_req:    {.spec.containers[0].resources.requests.cpu}
spec_cpu_lim:    {.spec.containers[0].resources.limits.cpu}
allocated_cpu:   {.status.containerStatuses[0].allocatedResources.cpu}
resize_status:   {.status.resize}
restarts:        {.status.containerStatuses[0].restartCount}
'
```

### Live CPU usage (requires metrics-server)

```bash
kubectl top pod -n cpu-burst-demo --containers
```

### Watch allocated resources change in real-time

```bash
watch -n 3 "kubectl get pod -n cpu-burst-demo \
  -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{.items[0].status.containerStatuses[0].allocatedResources}'"
```

### Show pod QoS class

```bash
kubectl get pod -n cpu-burst-demo \
  -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{.items[0].status.qosClass}'
# Burstable
```

---

## 11. Troubleshooting

### Pod stuck in `Pending` — `Insufficient cpu`

The worker node has 4 CPUs. kube-system pods consume ~110m at idle, leaving ~3890m allocatable. The burst request is 1500m, which should fit comfortably. If you see scheduling failures:

```bash
kubectl describe pod -n cpu-burst-demo <pod-name> | grep -A5 Events
```

Check for lingering pods from a previous run still counted against quota:

```bash
kubectl get pods -n cpu-burst-demo
kubectl delete namespace cpu-burst-demo --force --grace-period=0
```

### `cannot patch resource "pods" ... may not change fields`

You are hitting the Kubernetes immutability validation on the main pod endpoint. In K8s 1.33+, in-place resize **must** go through the `pods/resize` subresource. The fix is already in place in this repo — all `kubectl patch` calls use `--subresource=resize`.

If you see this error in your own scripts, verify:
```bash
kubectl patch pod <name> -n <ns> --subresource=resize --type=strategic -p '<json>'
```

### `cannot get resource "pods/resize"` (RBAC error)

`kubectl patch --subresource=resize` performs a GET before the PATCH. The ServiceAccount must have both `get` and `patch` on `pods/resize`. Check with:

```bash
kubectl auth can-i get pods/resize -n cpu-burst-demo \
  --as=system:serviceaccount:cpu-burst-demo:startup-resizer
# yes
```

### Resize rejected: `Pod QOS Class may not change as a result of resizing`

You attempted to resize CPU and memory simultaneously to equal values, which would flip QoS from Burstable to Guaranteed. Only resize CPU; leave memory as-is:

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

### VPA not applying resize — updater logs "request within recommended range"

This is the most common VPA issue in this demo. The updater only acts when the current CPU allocation falls **outside** `[lowerBound, upperBound]`. If a `VPACheckpoint` from a previous run captured the startup burst (1500m), the `upperBound` can be set above 1500m, causing the updater to see the pod as already adequately resourced.

```bash
# Check the updater's reasoning:
kubectl logs -n kube-system -l app.kubernetes.io/instance=vpa \
  -c updater --tail=20 | grep -i "not updating\|within recommended"

# Check the current recommendation bounds:
kubectl get vpa petclinic-vpa -n cpu-burst-demo \
  -o jsonpath='upper={.status.recommendation.containerRecommendations[0].upperBound.cpu}{"\n"}'
```

If `upperBound` >= `1500m`, delete the checkpoint so the Recommender re-learns from current (low) usage:

```bash
kubectl delete vpacheckpoint -n cpu-burst-demo --all
# Wait ~60–90s, then watch for the resize event:
kubectl get events -n cpu-burst-demo --sort-by='.lastTimestamp' | grep -i resize
```

### VPA Recommender has no recommendation yet

On a fresh cluster with no prior `VPACheckpoint`, wait 3–5 minutes after the pod becomes Ready before expecting a recommendation.

```bash
kubectl get vpacheckpoint -n cpu-burst-demo
kubectl describe vpa petclinic-vpa -n cpu-burst-demo | grep -A 20 "Recommendation:"
```

### Sidecar in `CrashLoopBackOff` — `unknown command "sh" for "kubectl"`

The `bitnami/kubectl` image sets `ENTRYPOINT=["kubectl"]`. If you only specify `command: ["/bin/sh", "..."]`, the entrypoint still wraps it. The correct override is:

```yaml
command: ["/bin/sh", "/scripts/resize.sh"]
```

This sets both the entrypoint and the command, replacing the default `ENTRYPOINT=["kubectl"]`.

---

## 12. Key API Concepts

### `pods/resize` subresource

Kubernetes 1.33 introduced a **dedicated subresource** for in-place pod resize. Direct PATCH on the main pod endpoint is rejected for resource fields by the immutability validator, even with the feature gate enabled.

```bash
# Correct (K8s 1.33+):
kubectl patch pod <name> --subresource=resize --type=strategic -p '...'

# Wrong (always rejected for resource fields):
kubectl patch pod <name> --type=strategic -p '...'
```

The RBAC for the subresource is separate from the main pod resource:

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods/resize"]
    verbs: ["get", "patch", "update"]   # get is required — kubectl does GET then PATCH
```

### `resizePolicy: restartPolicy: NotRequired`

This field in the container spec tells the kubelet that changing this resource should **not** restart the container. Without it, any resource change triggers a container restart — which defeats the entire purpose.

```yaml
resizePolicy:
  - resourceName: cpu
    restartPolicy: NotRequired
  - resourceName: memory
    restartPolicy: NotRequired
```

### QoS class immutability during resize

Kubernetes enforces that a resize cannot change the pod's QoS class:
- **Guaranteed**: `requests == limits` for all resources across all containers
- **Burstable**: at least one container has `requests < limits`
- **BestEffort**: no `requests` or `limits` set

Our pods start Burstable (`cpu 1500m req=lim`, `memory 512Mi req / 1Gi lim`). A CPU-only resize to `cpu 300m req=lim` keeps `memory requests < memory limits`, preserving Burstable QoS.

### `status.resize` field

The kubelet tracks the resize lifecycle in `pod.status.resize`:
- **`InProgress`** — kubelet is applying the resize
- **`Deferred`** — resize accepted but waiting for resources to be available
- **`Infeasible`** — resize cannot be applied (e.g. requested more than node capacity)
- **(empty)** — no active resize; if the spec matches allocatedResources, the resize is complete

---

## 13. Teardown

```bash
# Remove the current demo namespace
kubectl delete namespace cpu-burst-demo --ignore-not-found

# Full teardown: cluster + local Docker image + Helm repos
./scripts/teardown-cluster.sh
```

The teardown script is safe to run even if the cluster doesn't exist — every step checks for the resource before attempting deletion.
