# Stop Overprovisioning for Application Startup

> **Talk companion repo** — "Stop Overprovisioning for Application Startup"
> Demonstrates **In-Place Pod Resize** (GA in Kubernetes 1.33) as a zero-restart strategy for handling the JVM CPU burst at startup, without permanently overprovisioning your cluster.

---

## The Resource Gap Problem

Modern runtimes like the JDK perform intensive work at startup that they never repeat at runtime: class loading, bytecode verification, JIT compilation (C1 → C2), and GC heap initialization. This creates a sharp, short-lived CPU spike — the **Startup Burst** — followed by a long steady state where the same allocation sits mostly idle.

```
CPU
│
1500m ┤   ████
      │   ████   JIT / C2 warmup       Traditional static limit
      │   ████   (class loading +      (always allocated, always wasted)
 800m ┤   ████    hot-path JIT)
      │   ████  ╲
 300m ┤   ████   ╲__________________________________  Steady-state need
      │   ████
      └──────────────────────────────────────────── Time
         0s  30s  60s  90s  120s  ...
         │←── Burst window (~60–90s) ──→│←── Steady state ────────────
```

### Why this matters at scale

| Scenario | Pods | Burst CPU | Steady CPU | Wasted vCPUs |
|---|---|---|---|---|
| 10 services × 5 replicas | 50 | 1500m | 300m | **60 vCPUs** |
| 50 services × 5 replicas | 250 | 1500m | 300m | **300 vCPUs** |

Traditional solutions force a choice:
- **Overprovision** → waste money, inflate bin-packing costs, bloat cluster autoscaler triggers
- **Underprovision** → throttled JVM startup, slow rollouts, SLO violations under redeployment load

---

## The Solution: In-Place Pod Resize

Introduced as Alpha in Kubernetes 1.27 (KEP-1287) and promoted to **GA in 1.33**, In-Place Pod Vertical Scaling lets you change a running pod's CPU/Memory **without restarting the container**.

```yaml
# The field that prevents JVM restart on resize:
resizePolicy:
  - resourceName: cpu
    restartPolicy: NotRequired
  - resourceName: memory
    restartPolicy: NotRequired
```

The strategy:
1. Pod starts with **burst CPU** (1500m in this demo) to satisfy JIT compilation
2. Once the app signals readiness (Spring Boot Actuator probe passes), something detects it
3. That "something" patches the pod via the `pods/resize` subresource — kubelet resizes cgroups **in-place**
4. The JVM keeps running, the vCPUs are freed back to the node

---

## Demo Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  kind cluster: cpu-burst-lab  (Kubernetes v1.35.1)          │
│                                                             │
│  ┌─────────────────┐   ┌────────────────────────────────┐  │
│  │  control-plane  │   │  worker (demo/role=worker)     │  │
│  │                 │   │                                │  │
│  │  API Server     │   │  ┌──────────────────────────┐  │  │
│  │  Scheduler      │   │  │  Pod: petclinic          │  │  │
│  │  etcd           │   │  │                          │  │  │
│  └─────────────────┘   │  │  ┌────────────────────┐  │  │  │
│                        │  │  │ app (JDK 25)       │  │  │  │
│                        │  │  │ burst: 1500m CPU   │  │  │  │
│                        │  │  │ → resize → 300m    │  │  │  │
│                        │  │  └────────────────────┘  │  │  │
│                        │  └──────────────────────────┘  │  │
│                        └────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Docker | ≥ 27.x | [docs.docker.com](https://docs.docker.com/get-docker/) or `brew install --cask docker` |
| kind | ≥ 0.27.x | `brew install kind` |
| kubectl | ≥ 1.35 | `brew install kubectl` |
| helm | ≥ 3.17 | `brew install helm` |

> **macOS without Docker Desktop**: use [Colima](https://github.com/abiosoft/colima) (`brew install colima && colima start --cpu 4 --memory 8`)

---

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/graz-dev/k8s-cpu-burst-lab
cd k8s-cpu-burst-lab

# 2. Create the cluster
#    --with-vpa        → install VPA components
#    --with-monitoring → install Prometheus + Grafana (exposed at http://localhost:3000)
./scripts/setup-cluster.sh --with-vpa --with-monitoring

# 3. Pick an implementation and apply it
# The app image is pulled from ghcr.io/graz-dev/spring-petclinic-jdk25:latest automatically.
kubectl apply -k implementation-sidecar/
# or: kubectl apply -k implementation-deployment/
# or: kubectl apply -k implementation-vpa/
# or (CRD operator — two steps: install operator, then create policy):
#    kubectl apply --server-side -k implementation-operator/
#    kubectl apply -f implementation-operator/config/samples/startupboostpolicy.yaml

# 4. Watch the resize happen
# Terminal: kubectl logs -n cpu-burst-demo -l app.kubernetes.io/name=petclinic -c startup-resizer -f
# Browser:  http://localhost:3000  →  "CPU Burst Lab — Startup Resize" dashboard

# 5. Switch implementation (Grafana stays up)
kubectl delete namespace cpu-burst-demo
kubectl apply -k implementation-deployment/

# 6. Teardown
./scripts/teardown-cluster.sh
```

See [DOCUMENTATION.md](./DOCUMENTATION.md) for full per-implementation walkthroughs, expected output, and troubleshooting.

---

## Implementation Comparison

| | [Sidecar](./implementation-sidecar/) | [Deployment](./implementation-deployment/) | [VPA](./implementation-vpa/) | [Operator](./implementation-operator/) |
|---|---|---|---|---|
| **Trigger mechanism** | Polls Kubernetes API for container Ready state | Polls Kubernetes API every 10s for pods labelled `startup-boost=enabled` | VPA Recommender observes metrics; Updater applies in-place | Event-driven — reconcile fires within ms of pod Ready transition |
| **Resize timing** | Deterministic — fires within seconds of the readiness probe passing | Deterministic — fires within one poll interval (10s) of the Ready transition | Probabilistic — depends on metrics history and VPA's recommendation cycle | Deterministic — fires within milliseconds (no poll lag) |
| **JVM restart risk** | None — `restartPolicy: NotRequired` prevents it | None — `restartPolicy: NotRequired` prevents it | None for CPU resize in `InPlaceOrRecreate` mode | None — `restartPolicy: NotRequired` prevents it |
| **Additional infra** | None | One controller `Deployment` | VPA CRDs + Recommender + Updater + Admission Controller | CRD + one controller `Deployment` |
| **Ops scope** | One sidecar per pod | One controller for N workloads | One VPA stack for the whole cluster | One controller for N workloads; policy per workload |
| **Shrinkage Trap risk** | **None** — fires once, then `sleep infinity` | **Low** — pod annotation prevents re-triggering | **High** — continuous re-evaluation can shrink CPU prematurely during bursty periods | **None** — pod annotation prevents re-triggering; CRD status is observable |
| **Production readiness** | Good for simple, single-service adoption | Good for platform teams managing many workloads | Powerful but requires careful tuning of `minAllowed` and decay settings for JVM workloads | **Best overall** — self-documenting CRD, event-driven, observable status, zero poll lag |
| **Best for** | Quick wins, a single service or a few | Standardising the pattern across a platform | Long-running workloads with variable load patterns | Platform teams wanting a proper Kubernetes-native API |

### The "Shrinkage Trap" Explained

The Shrinkage Trap occurs when the resize mechanism fires too aggressively or too early, leaving the JVM CPU-starved:

- **Sidecar**: immune — it fires exactly once, then enters `sleep infinity`. No feedback loop possible.
- **Deployment**: low risk — the `startup-boost.io/resized=true` annotation prevents the hook from ever re-triggering on the same pod instance. Risk resets when the pod restarts, which is correct — a new pod needs burst CPU again.
- **VPA**: highest risk — VPA continuously re-evaluates. A quiet period after JIT warmup causes VPA to recommend low CPU. A secondary warmup spike (first real traffic hitting paths not yet compiled) then finds the JVM throttled. Mitigate with `minAllowed` and Recommender decay settings.

---

## Repository Structure

```
k8s-cpu-burst-lab/
├── kind-config.yaml                  # Cluster topology + feature gates
├── DOCUMENTATION.md                  # Detailed walkthrough + expected output
├── scripts/
│   ├── setup-cluster.sh              # Full bootstrap (kind + metrics-server + optional VPA)
│   └── teardown-cluster.sh           # Cluster + image + Helm repo cleanup
├── implementation-sidecar/
│   ├── README.md                     # Sidecar rationale and design notes
│   ├── namespace.yaml
│   ├── rbac.yaml
│   ├── configmap-sidecar-script.yaml
│   ├── deployment.yaml
│   └── kustomization.yaml
├── implementation-deployment/
│   ├── README.md                     # Deployment rationale and design notes
│   ├── namespace.yaml
│   ├── rbac.yaml
│   ├── configmap-hook.yaml           # controller.sh — the polling loop
│   ├── deployment-operator.yaml
│   ├── deployment-app.yaml
│   └── kustomization.yaml
├── implementation-vpa/
│   ├── README.md                     # VPA rationale and design notes
│   ├── namespace.yaml
│   ├── install-vpa.sh                # Helm install (fairwinds-stable/vpa 4.11.0)
│   ├── deployment.yaml
│   ├── vpa.yaml
│   └── kustomization.yaml
└── implementation-operator/
    ├── README.md                     # Operator rationale and design notes
    ├── api/v1alpha1/                 # StartupBoostPolicy CRD Go types
    ├── cmd/main.go                   # Controller manager entry point
    ├── internal/controller/          # Event-driven reconciler
    ├── config/                       # CRD manifest, RBAC, deployment, samples
    ├── Dockerfile                    # Multi-stage: golang:1.23 → distroless
    ├── Makefile                      # deps, build, publish, deploy, deploy-local
    └── kustomization.yaml
```

---

## Target Application

All demos use [spring-petclinic-jdk25](https://github.com/graz-dev/spring-petclinic-jdk25) — a Spring Boot 3 application built on JDK 25 with JIT compilation enabled, published publicly at `ghcr.io/graz-dev/spring-petclinic-jdk25:latest`. It exposes Spring Boot Actuator health endpoints:

| Endpoint | Used by |
|---|---|
| `/actuator/health` | `startupProbe` — allows up to 400s for JIT warmup |
| `/actuator/health/readiness` | `readinessProbe` — signals the app is ready for traffic |
| `/actuator/health/liveness` | `livenessProbe` — detects dead pods after startup |

The readiness probe passing is the event that triggers the resize in the sidecar and operator implementations.

---

## License

MIT
