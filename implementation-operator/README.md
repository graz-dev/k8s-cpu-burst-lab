# Implementation 4 — Custom Kubernetes Operator with CRD

This implementation builds a purpose-built Kubernetes controller that extends the cluster API with a `StartupBoostPolicy` custom resource. It is the most production-grade approach in this lab: event-driven, self-documenting, and observable through standard Kubernetes tooling.

## Why a CRD operator?

The three previous implementations trade off expressiveness, invasiveness, and latency in different ways:

| Approach | Trigger | Cluster scope | User-facing API |
|---|---|---|---|
| Sidecar | Poll every 5 s | Per-pod sidecar | Annotation on Pod |
| Simple operator | Poll every 10 s | Cluster-wide | Annotation on Deployment |
| VPA | Recommender interval | Cluster-wide | VerticalPodAutoscaler object |
| **CRD operator** | **Pod event** | **Namespace-scoped** | **StartupBoostPolicy object** |

### Key design choices

**Event-driven reconciliation, not polling.**
The controller registers a `Watches` hook on `corev1.Pod` events. When any pod in the namespace changes state, `mapPodToPolicy` translates the pod event into a reconcile request for the matching policy. The work queue in controller-runtime deduplicates concurrent events, so a noisy pod (many condition updates during startup) triggers at most one reconcile pass at a time. The resize fires within milliseconds of the pod's `Ready` condition transitioning to `True`.

**Status subresource on the CRD.**
`StartupBoostPolicy` exposes a `/status` subresource. The controller writes per-pod phase information (`Burst → Ready → Steady`) back to the object status. You can watch the full lifecycle with `kubectl get sbp -w` without tailing logs.

**Idempotency via pod annotation.**
Once the resize succeeds, the controller stamps `startup.boost.io/resized: "true"` on the pod. Subsequent reconcile passes skip that pod immediately, without issuing any API server calls beyond the initial cache read.

**QoS class preservation.**
The resize patch changes only CPU requests and limits. Memory is intentionally left at its original value. Kubernetes rejects any resize that would change a pod's QoS class (Burstable → Guaranteed), so touching memory would make the patch fail for most real workloads.

**`pods/resize` subresource.**
In Kubernetes 1.33 (GA) the in-place resize path requires patching `pods/<name>/resize`, not the pod directly. Direct PATCH on the pod endpoint is rejected by the immutability webhook even with `InPlacePodVerticalScaling` enabled. The controller uses `r.SubResource("resize").Patch(...)` from controller-runtime, which routes to the correct endpoint automatically.

**Stabilization window.**
`spec.stabilizationSeconds` delays the resize after `Ready`. This is useful when a readiness probe is configured to fire slightly before the JVM has finished class-loading (common in Spring Boot apps with actuator probes). Set it to `0` (the default) for immediate resize.

---

## Repository layout

```
implementation-operator/
├── api/v1alpha1/
│   ├── groupversion_info.go          # GVK registration
│   ├── startupboostpolicy_types.go   # CRD Go types
│   └── zz_generated.deepcopy.go     # DeepCopy methods
├── cmd/main.go                       # Manager entry point
├── internal/controller/
│   └── startupboostpolicy_controller.go  # Reconciler
├── config/
│   ├── namespace.yaml
│   ├── crd/startup.boost.io_startupboostpolicies.yaml
│   ├── rbac/                         # ServiceAccount, Role, RoleBinding
│   ├── manager/deployment.yaml       # Operator deployment
│   └── samples/
│       ├── deployment-app.yaml       # Spring PetClinic with burst CPU
│       └── startupboostpolicy.yaml   # Sample CRD instance
├── Dockerfile                        # Multi-stage: golang:1.23 → distroless
├── Makefile
└── kustomization.yaml
```

---

## Prerequisites

- `kind` cluster created with `scripts/setup-cluster.sh` (no extra flags needed)
- `kubectl` configured to point at the cluster (`kind-cpu-burst-lab` context)
- `docker` available on the host

---

## Running the demo

```bash
# From the repo root
cd implementation-operator

# Build the operator image and load it into the kind cluster, then apply all manifests
make deploy
```

The `deploy` target:
1. Runs `docker build` (multi-stage, ~2 min on first run due to module downloads)
2. Loads the image into kind with `kind load docker-image`
3. Applies the namespace, CRD, RBAC, operator deployment, app deployment, and policy with `kubectl apply -k .`

### Watch the operator

```bash
# Operator logs (event-driven reconcile loop)
kubectl logs -n cpu-burst-demo -l app.kubernetes.io/name=startup-boost-operator -f

# CRD status — shows per-pod phase
kubectl get sbp -n cpu-burst-demo
kubectl describe sbp petclinic-boost -n cpu-burst-demo

# Pod annotations stamped by the operator
kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{range .items[*]}{.metadata.name}: resized={.metadata.annotations.startup\.boost\.io/resized} steadyCPU={.metadata.annotations.startup\.boost\.io/steady-cpu}{"\n"}{end}'

# Allocated CPU (updates after resize is accepted)
kubectl get pod -n cpu-burst-demo -l app.kubernetes.io/name=petclinic \
  -o jsonpath='{range .items[*]}pod={.metadata.name} req={.spec.containers[0].resources.requests.cpu} allocated={.status.containerStatuses[0].allocatedResources.cpu}{"\n"}{end}'
```

### Expected lifecycle

```
startup-boost-operator: Reconcile triggered — policy petclinic-boost, 1 pod(s)
startup-boost-operator: Pod is Ready — applying in-place resize  pod=petclinic-xxx
startup-boost-operator: Resize complete  pod=petclinic-xxx  steadyCPU=300m
```

`kubectl get sbp -n cpu-burst-demo` output:

```
NAME              SELECTOR                          STEADYCPU   AGE
petclinic-boost   map[app.kubernetes.io/name:petclinic]   300m        45s
```

`kubectl describe sbp petclinic-boost -n cpu-burst-demo` status section:

```yaml
Status:
  Boosted Pods:
    Name:       petclinic-6d4f...
    Phase:      Steady
    Resized At: 2026-05-05T10:23:41Z
    Steady CPU: 300m
  Conditions:
    - Type:    Ready
      Status:  True
      Reason:  Reconciled
      Message: Managing 1 pod(s)
```

---

## Cleanup

```bash
make undeploy
```

Or from the repo root to reset the entire demo namespace:

```bash
kubectl delete namespace cpu-burst-demo
```

---

## Development notes

If you have Go installed locally:

```bash
# Download dependencies and generate go.sum
make deps   # runs: go mod tidy

# Compile the manager binary locally (useful for fast iteration)
make build  # output: bin/manager

# Run unit tests
make test
```

The Docker build uses `GONOSUMDB=*` and `-mod=mod` so it works without a pre-generated `go.sum` in the repository. Running `make deps` locally generates `go.sum` which can then be committed for reproducible hermetic builds.
