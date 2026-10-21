# Sidecar

A second container in the same Pod waits for the app to be Ready, then shrinks the app's CPU in place.

## How it works

1. The Pod starts with `startup-resizer` next to `petclinic`. The app runs at 1500m.
2. The sidecar polls `status.containerStatuses[name==petclinic].ready` every 2 seconds.
3. When the app is Ready it patches the Pod through the `resize` subresource to 300m (requests and limits).
4. It then waits until the Pod has no `PodResizePending` or `PodResizeInProgress` condition and `status.containerStatuses[].resources` reads 300m.
5. It logs completion and idles. The app container is never restarted.

The resize logic is `scripts/lib/resize.sh`, shared with the controller and with `lab.sh`.

## Run

```bash
./lab.sh sidecar
```

Or by hand: `kubectl apply -k implementation-sidecar/` and `kubectl logs -n cpu-burst-demo deploy/petclinic -c startup-resizer -f`.

## RBAC

Every Pod using the pattern runs as a ServiceAccount that can `get`, `list` and `watch` Pods and `get`, `patch` and `update` `pods/resize` in its namespace (`rbac.yaml`).

## Early-shrink behavior

High. The sidecar shrinks as soon as the readiness probe passes (within one 2 second poll) and has no delay setting. If the app is Ready before the runtime is warm, the CPU goes away early.

## Limitations

- Every workload carries the sidecar, its image (`alpine/k8s`, which has `kubectl` and `sh`) and a ServiceAccount with `pods/resize` rights.
- The sidecar resizes once per container start. If it restarts, it will request the same size again.
- Adding a workload means editing its Pod template.
