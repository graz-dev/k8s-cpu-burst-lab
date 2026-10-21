# k8s-cpu-burst-lab

A local lab for **CPU startup boost with In-Place Pod Resize** on Kubernetes.

Many runtimes need much more CPU at startup (JIT compilation, class and dependency loading, cache warmup) than they need once they are warm. Sizing Pods for that peak reserves CPU that sits idle for the rest of the Pod's life. Sizing them for the steady state throttles startup.

With In-Place Pod Resize (stable since Kubernetes v1.35) a Pod can start with extra CPU and give it back later, without a restart. This lab shows four ways to automate that, and lets you measure the tradeoffs on your laptop.

## How it works

1. The Pod starts with a higher CPU request and limit (1500m in this lab).
2. Something decides the app is warm.
3. It patches the Pod through the `resize` subresource down to the steady value (300m).
4. The kubelet updates the container's cgroup in place. The container keeps running.

```yaml
resizePolicy:
  - resourceName: cpu
    restartPolicy: NotRequired
```

## The four patterns

| | Sidecar | Controller | Operator | VPA |
|---|---|---|---|---|
| **Reacts to** | Polling from inside the Pod | Polling, one controller per namespace | Watch events | Usage history |
| **Shrinks at** | Ready | Ready + up to one poll | Ready + `stabilizationSeconds` | When requests fall outside the recommendation |
| **Add a workload** | Sidecar in the template | A label | A `StartupBoostPolicy` | A `VerticalPodAutoscaler` |
| **`pods/resize` rights** | Every Pod's ServiceAccount | One controller | One operator | VPA updater |
| **Early-shrink risk** | High | Medium | Low, tunable | Not startup-aware |

Each pattern has its own folder with a short README: [`implementation-sidecar`](./implementation-sidecar/), [`implementation-controller`](./implementation-controller/), [`implementation-operator`](./implementation-operator/), [`implementation-vpa`](./implementation-vpa/).

## Requirements

- Docker (Docker Desktop, or Colima: `colima start --cpu 6 --memory 10`)
- [kind](https://kind.sigs.k8s.io/) v0.33.0 or later
- kubectl v1.32 or later
- helm v3
- jq
- cgroup v2 on the container host (default on recent Docker Desktop and Colima)

## Quick start

```bash
git clone https://github.com/graz-dev/k8s-cpu-burst-lab
cd k8s-cpu-burst-lab

./lab.sh up          # kind cluster (Kubernetes v1.37), metrics, VPA, Prometheus and Grafana
./lab.sh operator    # run one pattern end to end: sidecar | controller | operator | vpa
./lab.sh down        # delete everything
```

Grafana is at http://localhost:3000 (`admin` / `admin`), dashboard **CPU Burst Lab**.

## Scenarios

| Command | What it shows |
|---|---|
| `./lab.sh compare` | Same app sized for steady state, for the peak, and with a boost: startup time, throttling, CPU held |
| `./lab.sh manual-resize` | One resize by hand, with the container's `cpu.max` before and after |
| `./lab.sh stabilization` | Operator shrinking right at Ready vs after a delay, under load |
| `./lab.sh jvm-cpus` | JVM thread pools sized at boost time vs pinned with `-XX:ActiveProcessorCount` |
| `./lab.sh watch` | Live table of Pods with CPU spec, actual CPU, restarts and throttling |
| `./lab.sh results` | Browse the measurements in a terminal UI (`--md` prints markdown) |

Set `PAUSE=1` to stop between steps. Results are written to `results/`.

## Repository layout

```
lab.sh                     entry point for every scenario
kind-config.yaml           cluster definition
scripts/                   setup, monitoring, shared helpers
monitoring/                Grafana dashboard
base/                      shared petclinic Deployment and Service
implementation-*/          the four patterns
scenarios/                 comparison and measurement workloads
DOCUMENTATION.md           detailed walkthrough and troubleshooting
```

The app under test is [spring-petclinic-jdk25](https://github.com/graz-dev/spring-petclinic-jdk25), a Spring Boot application on JDK 25.

## Further reading

- [Resize CPU and memory resources assigned to containers](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/)
- [Vertical Pod Autoscaler: in-place updates](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/features.md)

## License

MIT