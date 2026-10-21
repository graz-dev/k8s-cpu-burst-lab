# VPA

The Vertical Pod Autoscaler with `updateMode: InPlaceOrRecreate` resizes the Pod from its own recommendation.

## How it works

1. Petclinic starts at 1500m with no VerticalPodAutoscaler object.
2. `policy/vpa.yaml` is applied after the Pod is Ready. It controls CPU only, with `minAllowed` 300m and `maxAllowed` 1200m.
3. The recommender produces a target. The updater sees the Pod's 1500m request outside the recommended range and resizes it in place through the `resize` subresource.
4. If the resize were Infeasible or Deferred for more than 5 minutes, VPA would fall back to recreating the Pod.
5. The app container is never restarted.

VPA is installed by `./lab.sh up` (`install-vpa.sh`, Fairwinds chart 5.1.0, VPA 1.7.1). `InPlaceOrRecreate` needs no feature gate. The updater runs with `--in-place-skip-disruption-budget=true`.

## Run

```bash
./lab.sh vpa
```

The scenario has a second step: it runs `kubectl rollout restart` and records the new Pod's initial CPU request in `results/vpa-*.json` (`rollout.initial_cpu_request`, `rollout.boost_kept`). Once VPA has a recommendation, its admission controller can start new Pods at the recommended CPU, which removes the boost on the next rollout.

## RBAC

The VPA components bring their own ClusterRoles. The updater is the one that needs `pods/resize`. Nothing is added by this lab.

## Early-shrink behavior

Not startup-aware. VPA acts on its recommendation, which comes from usage history, not from the Pod's readiness. The resize can land before the runtime is warm, and it applies to the next rollout too.

## Limitations

- The recommendation needs usage history. A fresh cluster can take minutes; a cluster that has seen the workload before can resize at once.
- `minAllowed` is how the lab pins the steady value to 300m, because petclinic uses less than that when idle.
- With `resizePolicy` memory set to `RestartContainer`, the disruption-budget flag does not apply to this Pod. The lab has no PodDisruptionBudget, so the resize is not blocked.
- It is a general autoscaler, not a startup tool: it keeps adjusting after the first resize.
