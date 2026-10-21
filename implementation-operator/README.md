# Operator

The `StartupBoostPolicy` operator watches Pods and shrinks them in place, with an optional delay after Ready.

## How it works

1. Install the operator once: CRD `startupboostpolicies.startup.boost.io`, a ClusterRole, and the manager Deployment in `cpu-burst-operator`.
2. A `StartupBoostPolicy` in a workload's namespace selects Pods by label and names the container and its `steadyCPU`.
3. The operator reconciles on Pod events. A matching Pod reports phase `Burst` until it is Ready.
4. Once the Pod has been Ready for `stabilizationSeconds` (default 0), the operator patches the `resize` subresource and annotates the Pod. The phase becomes `Ready` while it waits and `Steady` after the patch.
5. The app container is never restarted.

## Run

```bash
./lab.sh operator
```

Or by hand:

```bash
kubectl apply -k implementation-operator/         # operator
kubectl apply -k implementation-operator/demo/    # petclinic and a policy
kubectl get sbp -n cpu-burst-demo -o wide
```

`config/samples/startupboostpolicy-stabilized.yaml` sets `stabilizationSeconds: 30`.

## RBAC

A ClusterRole bound to the operator's ServiceAccount: `get`, `list`, `watch`, `patch` on Pods, `get`, `patch`, `update` on `pods/resize`, `get`, `list`, `watch` on policies and `get`, `update`, `patch` on their status, plus events and leases (`config/rbac/`). It watches every namespace, so one operator serves all of them.

## Early-shrink behavior

Low, and tunable. `stabilizationSeconds` is the only delay setting in the four patterns. It is a fixed wait after Ready, not a check that the runtime is warm.

## Limitations

- A CRD and a cluster-wide role to install and keep.
- The policy phase `Steady` is set when the API server accepts the resize patch, not when the kubelet finishes. `lab.sh` checks the Pod conditions and `status.containerStatuses[].resources` itself.
- The operator image is built from this repository by CI and pinned by tag in `config/manager/deployment.yaml`.
- Controller-runtime and the CRD types are in `api/`, `cmd/` and `internal/`; `make` targets in this folder build and load a local image.
