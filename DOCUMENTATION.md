# CPU Burst Lab: documentation

A longer walkthrough of the lab. The [README](README.md) has the short version.

## Contents

1. [Background](#1-background)
2. [Requirements](#2-requirements)
3. [Repository layout](#3-repository-layout)
4. [Bring the lab up](#4-bring-the-lab-up)
5. [How a resize is detected](#5-how-a-resize-is-detected)
6. [The four patterns](#6-the-four-patterns)
7. [Scenarios](#7-scenarios)
8. [Dashboard](#8-dashboard)
9. [Results](#9-results)
10. [Observability cheat sheet](#10-observability-cheat-sheet)
11. [Troubleshooting](#11-troubleshooting)
12. [API concepts](#12-api-concepts)
13. [Teardown](#13-teardown)

---

## 1. Background

Many runtimes need more CPU while they start than once they are warm. A JVM loads and verifies classes, compiles hot methods with the JIT, initializes the heap and runs the application's bootstrap code. Spring Petclinic, the app in this lab, is no exception.

A Pod has two ways to be sized, and both cost something:

| Sizing | Cost |
|---|---|
| For the peak | The scheduler reserves CPU that the Pod no longer uses once it is warm. |
| For the steady state | Startup is throttled by the CFS quota and takes longer. |

In-Place Pod Resize (stable since Kubernetes v1.35) removes the choice: the Pod starts with the peak allocation and gives it back later, without a container restart. The kubelet rewrites the container's cgroup limits in place.

The open question is **when to shrink**. Shrinking before the runtime is warm is an **early shrink**: the Pod loses CPU while it still needs it. The four patterns in this lab differ mostly in how they decide, and the scenarios measure what that costs.

## 2. Requirements

| Item | Value |
|---|---|
| kind | v0.33.0 or later |
| Node image | `kindest/node:v1.37.0` (pinned by digest in `kind-config.yaml`) |
| Cluster | 1 control plane and 1 worker labeled `demo/role=worker` |
| kubectl | v1.32 or later (`--subresource=resize`) |
| helm | v3 |
| jq | any recent version (`lab.sh` builds its results with it) |
| cgroups | v2 on the container host: the scenarios read `cpu.max` and `cpu.stat` |
| Host size | At least 4 CPUs and 8 GiB for the container host |

On macOS with Colima: `colima start --cpu 6 --memory 10`. Docker Desktop with equivalent resources works, and so does a Linux host.

In-Place Pod Resize is stable since v1.35 and its feature gate is locked on, so `kind-config.yaml` sets no feature gates.

`lab.sh` checks these before it does anything and exits non-zero with a message when one fails: missing tools, kubectl too old, cgroup v1, a host or worker that is too small, a missing cluster.

## 3. Repository layout

```
lab.sh                     entry point for every command
Makefile                   thin targets that call lab.sh
kind-config.yaml           cluster definition
scripts/
  setup-cluster.sh         kind cluster, metrics-server, optional VPA and monitoring
  install-monitoring.sh    kube-prometheus-stack and the Grafana dashboard
  teardown-cluster.sh
  lib/                     shell helpers (resize.sh is shared with the in-cluster scripts)
  scenarios/               one file per lab.sh scenario
monitoring/dashboard.json  the Grafana dashboard
base/                      the petclinic Deployment and Service that every overlay builds on
implementation-sidecar/    pattern 1
implementation-controller/ pattern 2
implementation-operator/   pattern 3 (Go operator and the StartupBoostPolicy CRD)
implementation-vpa/        pattern 4
scenarios/                 compare, jvm-cpus, manual-resize, stabilization, load (k6)
results/                   measurements (gitignored)
```

### The app

`ghcr.io/graz-dev/spring-petclinic-jdk25:0.2.0` is Spring Boot on `eclipse-temurin:25-jre`, so `sh` and `cat` exist in the container. It bundles an OpenTelemetry Java agent, which the lab disables with `OTEL_SDK_DISABLED=true`.

`base/deployment.yaml` is the single definition of the workload:

- CPU request and limit 1500m, memory request 512Mi and limit 1Gi. Memory requests below limits keep the Pod Burstable, so the CPU request can equal the CPU limit without changing the QoS class.
- `resizePolicy`: CPU `NotRequired` (resize in place), memory `RestartContainer`.
- Startup, readiness and liveness probes on the Actuator endpoints.
- Every pattern and scenario is a kustomize overlay of this base.

### Images and namespaces

Every image is pinned by version: the app, the operator (`sha-84e5843`), `alpine/k8s:1.37.1` for the sidecar and the controller (it has `kubectl` and `/bin/sh`, for amd64 and arm64) and `grafana/k6:1.8.2`. No image uses a floating tag.

| Namespace | Used by |
|---|---|
| `cpu-burst-demo` | the four patterns |
| `cpu-burst-compare` | `compare` |
| `cpu-burst-manual` | `manual-resize` |
| `cpu-burst-stabilization` | `stabilization` |
| `cpu-burst-jvm` | `jvm-cpus` |
| `cpu-burst-operator` | the operator (installed on demand, kept by `reset`) |

Everything the lab creates is labeled `app.kubernetes.io/part-of: cpu-burst-lab` and `lab.scenario: <name>`.

## 4. Bring the lab up

```bash
./lab.sh up
```

This runs `scripts/setup-cluster.sh --with-vpa --with-monitoring`, then preloads every image into the kind nodes so the scenarios work with no network. The preload saves one platform with `docker save --platform` and loads the archive, because `kind load docker-image` fails on multi-platform images with Docker's containerd image store.

Grafana is at http://localhost:3000 (`admin` / `admin`). If port 3000 is taken on the host, set `GRAFANA_HOST_PORT=3001` before `./lab.sh up`.

Other lifecycle commands:

```bash
./lab.sh reset   # delete every lab namespace, keep the cluster and monitoring
./lab.sh down    # delete the cluster
```

Every scenario starts by deleting and recreating its own namespace, so running it twice in a row needs no `reset`. A scenario never touches `monitoring`, `kube-system` or another scenario's namespace.

## 5. How a resize is detected

A resize patch is accepted immediately. The kubelet applies it afterwards, and it can take a moment (or be deferred). Since v1.33 the status of that work is in two Pod conditions, not in `.status.resize`, which no longer exists:

- `PodResizePending`, with reason `Infeasible` or `Deferred`
- `PodResizeInProgress`

A resize is **done** when neither condition is present **and** `status.containerStatuses[name==X].resources` equals the resources in the Pod spec. The second half matters: the `resources` field in the container status is what the kubelet actually configured.

`scripts/lib/resize.sh` implements this once, in POSIX `sh`: `resize_patch`, `resize_snapshot`, `resize_is_done` and `resize_wait`. The host scripts source it, and the sidecar and the controller mount it from a ConfigMap generated from the same file. All of them select the container by name, never by index.

## 6. The four patterns

| | Sidecar | Controller | Operator | VPA |
|---|---|---|---|---|
| Reacts to | Polling from inside the Pod (2 s) | Polling, one controller per namespace (5 s) | Pod watch events | Usage history |
| Shrinks at | Ready | Ready plus up to one poll | Ready plus `stabilizationSeconds` | When the recommendation excludes the current request |
| Add a workload | A sidecar in the Pod template | A label | A `StartupBoostPolicy` | A `VerticalPodAutoscaler` |
| `pods/resize` rights | Every Pod's ServiceAccount | One controller | One operator | The VPA updater |
| Early-shrink risk | High | Medium | Low, tunable | Not startup-aware |

The operator is the only pattern with a configurable delay. Each folder has a short README: [sidecar](implementation-sidecar/README.md), [controller](implementation-controller/README.md), [operator](implementation-operator/README.md), [vpa](implementation-vpa/README.md).

Run any of them end to end with `./lab.sh sidecar|controller|operator|vpa`. Each one applies the pattern, streams the log of whatever does the resizing, shows the resize land, and prints the Pod's `status.containerStatuses[].resources`, `restartCount` and `cpu.max`.

For `operator` it also prints `kubectl get sbp -o wide` and the per-Pod status phases (`Burst`, `Ready`, `Steady`). For `vpa` it adds a second step: it triggers `kubectl rollout restart` and records the new Pod's initial CPU request, to test the hypothesis that once VPA has a recommendation, new Pods start at the steady CPU and the boost is gone. The result is in `rollout.initial_cpu_request` and `rollout.boost_kept`.

## 7. Scenarios

Every scenario narrates its steps (`==> Step 2/4: ...`). With `PAUSE=1` it waits for Enter before each step, for a live demo. Without it, it runs straight through. It records RFC 3339 timestamps of the scenario and of its key events (Pod created, Ready, resize requested, resize done) so screenshots can target exact time windows, and it never waits with a fixed sleep: it polls a condition with a timeout.

### compare

```bash
./lab.sh compare              # one Deployment at a time
./lab.sh compare --parallel   # all three at once
```

Three Deployments of the same app in `cpu-burst-compare`:

- `petclinic-steady`: 300m request and limit, no resize
- `petclinic-peak`: 1500m request and limit, no resize
- `petclinic-boost`: starts at 1500m, shrunk to 300m by the operator with `stabilizationSeconds: 30`

By default each one is Ready and settled (CPU below 100m for two samples) before the next starts, so they do not compete for host CPU. For each it records the time to Ready, Spring's own startup time from the `Started PetClinicApplication in X seconds` log line, `nr_throttled` and `throttled_usec` from `cpu.stat` at Ready, and the CPU request after a 180 second hold.

### manual-resize

```bash
./lab.sh manual-resize
```

One Pod at 1500m. It prints `cpu.max` and the container status resources, patches the Pod to 300m with `--subresource resize`, polls the conditions until the resize is done, then prints both again with `restartCount`. Everything shown is read from the live Pod; nothing is hardcoded.

### stabilization

```bash
./lab.sh stabilization
LOAD_VUS=10 ./lab.sh stabilization
```

The operator shrinks right at Ready (`stabilizationSeconds: 0`, run A), then 30 seconds after (run B). In both runs a k6 Job starts as soon as the Pod is Ready. It records the throttling ratio (`nr_throttled / nr_periods` from `cpu.stat`) and the k6 latency for the 2 minutes after the resize.

Both runs use the same Grafana window, anchored on the resize: 60 seconds before to 120 seconds after, written to `runs.<run>.window` in the results, so two screenshots sit side by side on the same time scale.

### jvm-cpus

```bash
./lab.sh jvm-cpus
```

Two boost Deployments that differ only in `-XX:ActiveProcessorCount=1`. Both start at 1500m, where the JVM detects 2 CPUs, and the operator shrinks them to 300m after 30 seconds. The same k6 load then runs against each. The processor count each JVM detected comes from `-Xlog:gc+init=info` (the line `CPUs: N total, M available`; `-Xlog:os+container` prints it only at trace level). If the two variants do not differ, that is the result.

### watch and results

```bash
./lab.sh watch [namespace]   # refreshing table, one row per Pod
./lab.sh results             # terminal UI over results/ (j/k run, J/K scroll, t raw JSON, q quit)
./lab.sh results --md        # latest run of every scenario as markdown
```

```
POD                              PHASE    READY CPU SPEC CPU ACTUAL RESTARTS THROTTLED
petclinic-boost-5b98fbf67b-pqsnq Running  true  300m     300m       0        75
```

`CPU ACTUAL` is `status.containerStatuses[].resources`, `THROTTLED` is `nr_throttled` from the container's `/sys/fs/cgroup/cpu.stat`.

### Load generator

`scenarios/load` is a k6 Job (`grafana/k6:1.8.2`) hitting the home page, the owner search and the vets page. `LOAD_VUS` (default 5) and `LOAD_DURATION` (seconds, default 120) set its size. The script prints one line per request, and `lab.sh` computes nearest-rank percentiles over an exact time window from those lines. k6's own whole-run summary is stored as well.

## 8. Dashboard

`monitoring/dashboard.json` is the single source for the Grafana dashboard **CPU Burst Lab**. It has two variables, `namespace` and `pod` (a regex, default `petclinic.*`), and three panels:

- CPU used, request and limit per Pod, in millicores
- Throttling ratio per Pod: `rate(container_cpu_cfs_throttled_periods_total[1m]) / rate(container_cpu_cfs_periods_total[1m])`
- Container restarts

`scripts/install-monitoring.sh` wraps the file in a ConfigMap labeled `grafana_dashboard=1`, which the Grafana sidecar imports. The cAdvisor metrics are scraped every 10 seconds, the default cAdvisor housekeeping interval.

## 9. Results

Each run writes `results/<scenario>-<YYYYmmdd-HHMMSS>.json` (raw, with `events` timestamps and the scenario's measurements) and appends a row to `results/<scenario>.md`. The folder is gitignored.

`./lab.sh results` opens a terminal UI (`scripts/results-tui.py`, Python standard library only): runs on the left, grouped by scenario with the newest first, and a view of the selected run on the right, with tables and bars for the numbers and the timeline of events. Piped or redirected, it prints the latest run of every scenario as plain text.

Timing values that come from Pod conditions have a resolution of one second. A value that was not measured is `TBD`; no number in this repository is estimated.

## 10. Observability cheat sheet

```bash
# Spec versus what the kubelet applied, for the app container
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[?(@.name=="petclinic")].resources}{"\n"}{.status.containerStatuses[?(@.name=="petclinic")].resources}{"\n"}'

# Resize conditions (empty when no resize is in flight)
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.conditions[?(@.type=="PodResizePending")]}{.status.conditions[?(@.type=="PodResizeInProgress")]}{"\n"}'

# The cgroup the kubelet configured, and the throttling counters
kubectl exec -n <ns> <pod> -c petclinic -- cat /sys/fs/cgroup/cpu.max
kubectl exec -n <ns> <pod> -c petclinic -- cat /sys/fs/cgroup/cpu.stat

# QoS class (must stay Burstable)
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.qosClass}{"\n"}'

# Operator
kubectl get sbp -A -o wide
kubectl logs -n cpu-burst-operator deploy/startup-boost-operator -f
```

`cpu.max` has the form `$MAX $PERIOD`. The kubelet's default CFS period is 100 ms, so a 1500m limit reads `150000 100000` and a 300m limit reads `30000 100000`.

## 11. Troubleshooting

### `kind create cluster` fails with "Too many open files" (Colima)

The VM's inotify limit is too low when other clusters run in it. Raise it inside the VM and retry:

```bash
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288
```

### Port 3000 is already allocated

Another container or process holds the port. Use `GRAFANA_HOST_PORT=3001 ./lab.sh up`.

### Pod stuck in `Pending` with `Insufficient cpu`

The worker cannot fit the Pod at 1500m. Check `kubectl describe node -l demo/role=worker` for allocatable CPU. `compare --parallel` needs room for 1500m + 1500m + 300m on top of monitoring.

### `cannot patch resource "pods" ... may not change fields`

The patch went to the Pod endpoint instead of the subresource. Use `kubectl patch ... --subresource=resize`.

### `cannot get resource "pods/resize"` (RBAC)

`kubectl patch --subresource=resize` does a GET and then a PATCH, so the Role needs `get` and `patch` on `pods/resize`. Check with `kubectl auth can-i patch pods/resize --as=system:serviceaccount:<ns>:<sa> -n <ns>`.

### `Pod QOS Class may not change as a result of resizing`

Changing every request and limit to equal values would flip Burstable to Guaranteed. The lab changes CPU only and keeps memory requests below limits.

### VPA does not resize

Look at the updater's decision and at the recommendation:

```bash
kubectl logs -n kube-system deploy/vpa-updater | grep cpu-burst-demo
kubectl get vpa petclinic-vpa -n cpu-burst-demo -o jsonpath='{.status.recommendation}{"\n"}'
```

The Pod's request must fall outside the recommended `[lowerBound, upperBound]`. In this lab `maxAllowed` (1200m) sits below the 1500m boost for that reason. On a fresh cluster the recommender needs usage history before it produces a target.

### Sidecar or controller in `CrashLoopBackOff` with `unknown command "sh"`

The image has no shell. Use `alpine/k8s`, which has both `kubectl` and `sh`.

## 12. API concepts

### The `resize` subresource

Resource changes on a running Pod go through `pods/<name>/resize`. A direct patch on the Pod is rejected for resource fields.

```bash
kubectl patch pod <name> --subresource=resize --type=strategic -p '{"spec":{"containers":[{"name":"petclinic","resources":{"requests":{"cpu":"300m"},"limits":{"cpu":"300m"}}}]}}'
```

### `resizePolicy`

`restartPolicy: NotRequired` tells the kubelet to change the cgroup without restarting the container. `RestartContainer` restarts it. CPU is `NotRequired` and memory is `RestartContainer` in the base.

### QoS class

A resize cannot change a Pod's QoS class. The lab's Pods are Burstable (memory request 512Mi, limit 1Gi), and a CPU-only resize keeps them so.

### Desired, allocated and actual

`spec.containers[].resources` is the desired state. `status.containerStatuses[].allocatedResources` is what the kubelet accepted. `status.containerStatuses[].resources` is what is configured on the running container. The lab compares the first and the last.

### CFS bandwidth

A limit becomes `cpu.max`. When a container uses its quota before the period ends, it is throttled until the next period. `cpu.stat` counts `nr_periods`, `nr_throttled` and `throttled_usec`, and the dashboard's throttling ratio is `nr_throttled / nr_periods` over a window.

## 13. Teardown

```bash
./lab.sh reset   # delete the lab namespaces, keep the cluster
./lab.sh down    # delete the cluster and the Helm repos added by setup
```
