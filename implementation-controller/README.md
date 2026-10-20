# Controller

One polling controller per namespace shrinks every labeled Pod that is Ready.

## How it works

1. The app Pods carry the label `startup-boost=enabled` and start at 1500m.
2. A `Deployment` runs `controller.sh` in an `alpine/k8s` container. Every 5 seconds it lists the labeled Pods.
3. For a Pod that is Ready, has no resize in flight and carries no `startup-boost.io/resized` annotation, it patches `requests.cpu` and `limits.cpu` of the `petclinic` container to 300m through the `resize` subresource.
4. It annotates the Pod so it is never resized twice, then waits until the conditions are clear and `status.containerStatuses[].resources` reads 300m.
5. The app container is never restarted.

The resize logic is `scripts/lib/resize.sh`, shared with the sidecar and with `lab.sh`.

## Run

```bash
./lab.sh controller
```

Or by hand: `kubectl apply -k implementation-controller/` and `kubectl logs -n cpu-burst-demo deploy/startup-boost-controller -f`.

## RBAC

One ServiceAccount in the namespace: `get`, `list`, `watch` and `patch` on Pods, and `get`, `patch`, `update` on `pods/resize` (`rbac.yaml`). The workload Pods need no API access.

## Early-shrink behavior

Medium. The controller shrinks at Ready plus up to one poll interval (`POLL_INTERVAL`, 5 seconds). The delay is incidental: there is no setting that means "wait until warm".

## Limitations

- Polling, so the resize lands up to one interval after Ready.
- Namespace-scoped Role. Another namespace needs its own controller.
- The "handled" state is a Pod annotation. A Pod created from a template that already has the annotation would be skipped.
- Opt-in by label only. Target CPU and container name are the controller's own environment variables, not per-workload settings.
