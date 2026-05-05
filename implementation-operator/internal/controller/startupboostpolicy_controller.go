package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	startupv1alpha1 "github.com/graz-dev/k8s-cpu-burst-lab/implementation-operator/api/v1alpha1"
)

const (
	annotationResized   = "startup.boost.io/resized"
	annotationResizedAt = "startup.boost.io/resized-at"
	annotationSteadyCPU = "startup.boost.io/steady-cpu"
	annotationPolicy    = "startup.boost.io/policy"
	conditionReady      = "Ready"
	fieldManager        = "startup-boost-operator"
)

// StartupBoostPolicyReconciler reconciles StartupBoostPolicy objects.
//
// The reconciler is triggered by two event sources:
//  1. Changes to StartupBoostPolicy objects (create, update, delete).
//  2. Changes to Pods in the same namespace — specifically, when a pod's Ready
//     condition transitions to True. The mapPodToPolicy function translates
//     a pod event into the name of the policy that covers it, so the reconciler
//     fires within milliseconds of the pod becoming Ready.
//
// This is the core difference from a polling loop: no timer, no 10-second lag.
// The shared informer cache in controller-runtime maintains a local in-memory
// snapshot of all pods and policies. The reconciler reads from the cache (fast,
// no API server round-trip) and only writes when a resize or status update is needed.
type StartupBoostPolicyReconciler struct {
	client.Client
}

// +kubebuilder:rbac:groups=startup.boost.io,resources=startupboostpolicies,verbs=get;list;watch
// +kubebuilder:rbac:groups=startup.boost.io,resources=startupboostpolicies/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;patch
// +kubebuilder:rbac:groups="",resources=pods/resize,verbs=get;patch;update
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch
// +kubebuilder:rbac:groups=coordination.k8s.io,resources=leases,verbs=get;list;watch;create;update;patch;delete

func (r *StartupBoostPolicyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// ── 1. Fetch the StartupBoostPolicy ────────────────────────────────────────
	policy := &startupv1alpha1.StartupBoostPolicy{}
	if err := r.Get(ctx, req.NamespacedName, policy); err != nil {
		// Object deleted between the event and this reconcile call — nothing to do.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// ── 2. List pods matching the selector in the same namespace ──────────────
	// Reads from the controller-runtime cache — no API server round-trip.
	selector, err := metav1.LabelSelectorAsSelector(&policy.Spec.Selector)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("invalid selector: %w", err)
	}

	podList := &corev1.PodList{}
	if err := r.List(ctx, podList,
		client.InNamespace(policy.Namespace),
		client.MatchingLabelsSelector{Selector: selector},
	); err != nil {
		return ctrl.Result{}, fmt.Errorf("listing pods: %w", err)
	}

	// ── 3. Process each pod — resize if Ready and not yet done ────────────────
	podStatuses := make([]startupv1alpha1.PodBoostStatus, 0, len(podList.Items))
	requeueAfter := time.Duration(0)

	for i := range podList.Items {
		pod := &podList.Items[i]
		status, requeue := r.processPod(ctx, policy, pod, logger)
		podStatuses = append(podStatuses, status)
		if requeue > 0 && (requeueAfter == 0 || requeue < requeueAfter) {
			requeueAfter = requeue
		}
	}

	// ── 4. Write status back to the CRD ───────────────────────────────────────
	// Using a patch so we don't clobber concurrent updates.
	patch := client.MergeFrom(policy.DeepCopy())
	policy.Status.BoostedPods = podStatuses
	setCondition(policy, conditionReady, metav1.ConditionTrue, "Reconciled",
		fmt.Sprintf("Managing %d pod(s)", len(podList.Items)))
	if err := r.Status().Patch(ctx, policy, patch); err != nil && !apierrors.IsNotFound(err) {
		return ctrl.Result{}, fmt.Errorf("updating status: %w", err)
	}

	if requeueAfter > 0 {
		return ctrl.Result{RequeueAfter: requeueAfter}, nil
	}
	return ctrl.Result{}, nil
}

// processPod decides what to do with a single pod and returns its status.
// It also returns a non-zero requeue duration when stabilization delay is in effect.
func (r *StartupBoostPolicyReconciler) processPod(
	ctx context.Context,
	policy *startupv1alpha1.StartupBoostPolicy,
	pod *corev1.Pod,
	logger interface{ Info(string, ...any); Error(error, string, ...any) },
) (startupv1alpha1.PodBoostStatus, time.Duration) {

	// Already resized in a previous reconcile — read the annotation and report Steady.
	if pod.Annotations[annotationResized] == "true" {
		t, _ := time.Parse(time.RFC3339, pod.Annotations[annotationResizedAt])
		mt := metav1.NewTime(t)
		return startupv1alpha1.PodBoostStatus{
			Name:      pod.Name,
			Phase:     startupv1alpha1.PhaseSteady,
			ResizedAt: &mt,
			SteadyCPU: pod.Annotations[annotationSteadyCPU],
		}, 0
	}

	// Pod not yet Ready — still in burst phase.
	if !isPodReady(pod) {
		return startupv1alpha1.PodBoostStatus{
			Name:  pod.Name,
			Phase: startupv1alpha1.PhaseBurst,
		}, 0
	}

	// Pod is Ready but not yet resized. Check stabilization delay.
	if policy.Spec.StabilizationSeconds > 0 {
		readyTime := podReadyTime(pod)
		elapsed := time.Since(readyTime)
		delay := time.Duration(policy.Spec.StabilizationSeconds) * time.Second
		if elapsed < delay {
			remaining := delay - elapsed
			logger.Info("Stabilization delay in effect", "pod", pod.Name,
				"remaining", remaining.Round(time.Second))
			return startupv1alpha1.PodBoostStatus{
				Name:    pod.Name,
				Phase:   startupv1alpha1.PhaseReady,
				Message: fmt.Sprintf("stabilizing for %.0fs", remaining.Seconds()),
			}, remaining
		}
	}

	// ── Apply the in-place resize ─────────────────────────────────────────────
	logger.Info("Pod is Ready — applying in-place resize", "pod", pod.Name)

	var lastSteadyCPU string
	for _, cs := range policy.Spec.Containers {
		if err := r.applyResize(ctx, pod, cs); err != nil {
			logger.Error(err, "Resize patch failed — will retry next reconcile",
				"pod", pod.Name, "container", cs.Name)
			return startupv1alpha1.PodBoostStatus{
				Name:    pod.Name,
				Phase:   startupv1alpha1.PhaseFailed,
				Message: err.Error(),
			}, 10 * time.Second
		}
		lastSteadyCPU = cs.SteadyCPU
	}

	// ── Annotate the pod (idempotency guard + audit trail) ───────────────────
	now := time.Now().UTC()
	annotatedPod := pod.DeepCopy()
	if annotatedPod.Annotations == nil {
		annotatedPod.Annotations = make(map[string]string)
	}
	annotatedPod.Annotations[annotationResized] = "true"
	annotatedPod.Annotations[annotationResizedAt] = now.Format(time.RFC3339)
	annotatedPod.Annotations[annotationSteadyCPU] = lastSteadyCPU
	annotatedPod.Annotations[annotationPolicy] = policy.Name

	if err := r.Patch(ctx, annotatedPod, client.MergeFrom(pod)); err != nil && !apierrors.IsNotFound(err) {
		// Annotation failure is non-fatal — log it; the resize already succeeded.
		// The next reconcile will see the pod is ready + not annotated and will
		// attempt another resize (which is idempotent).
		logger.Error(err, "Failed to annotate pod after resize", "pod", pod.Name)
	}

	mt := metav1.NewTime(now)
	logger.Info("Resize complete", "pod", pod.Name, "steadyCPU", lastSteadyCPU)
	return startupv1alpha1.PodBoostStatus{
		Name:      pod.Name,
		Phase:     startupv1alpha1.PhaseSteady,
		ResizedAt: &mt,
		SteadyCPU: lastSteadyCPU,
	}, 0
}

// applyResize submits the in-place resize patch for one container via the
// pods/resize subresource (Kubernetes 1.35+ GA for in-place pod resize).
// Only CPU is changed; memory limits are left intact to avoid flipping the
// pod's QoS class from Burstable to Guaranteed, which K8s rejects at resize time.
func (r *StartupBoostPolicyReconciler) applyResize(
	ctx context.Context,
	pod *corev1.Pod,
	cs startupv1alpha1.ContainerBoostSpec,
) error {
	patch := resizePatch{
		Spec: resizePatchSpec{
			Containers: []resizePatchContainer{{
				Name: cs.Name,
				Resources: resizePatchResources{
					Requests: map[string]string{"cpu": cs.SteadyCPU},
					Limits:   map[string]string{"cpu": cs.SteadyCPU},
				},
			}},
		},
	}
	patchBytes, err := json.Marshal(patch)
	if err != nil {
		return err
	}

	// controller-runtime's SubResource("resize") targets pods/<name>/resize —
	// the dedicated API subresource introduced in K8s 1.35 for in-place resize.
	// A direct PATCH on the pod endpoint is rejected by the immutability validator
	// even with InPlacePodVerticalScaling enabled.
	return r.SubResource("resize").Patch(ctx, pod,
		client.RawPatch(types.StrategicMergePatchType, patchBytes),
	)
}

// ── Helper types for the resize patch body ────────────────────────────────────

type resizePatch struct {
	Spec resizePatchSpec `json:"spec"`
}
type resizePatchSpec struct {
	Containers []resizePatchContainer `json:"containers"`
}
type resizePatchContainer struct {
	Name      string              `json:"name"`
	Resources resizePatchResources `json:"resources"`
}
type resizePatchResources struct {
	Requests map[string]string `json:"requests"`
	Limits   map[string]string `json:"limits"`
}

// ── Pod helper functions ──────────────────────────────────────────────────────

func isPodReady(pod *corev1.Pod) bool {
	for _, c := range pod.Status.Conditions {
		if c.Type == corev1.PodReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

// podReadyTime returns the time the pod's Ready condition last transitioned to True.
func podReadyTime(pod *corev1.Pod) time.Time {
	for _, c := range pod.Status.Conditions {
		if c.Type == corev1.PodReady && c.Status == corev1.ConditionTrue {
			return c.LastTransitionTime.Time
		}
	}
	return time.Now()
}

// ── Status condition helper ───────────────────────────────────────────────────

func setCondition(policy *startupv1alpha1.StartupBoostPolicy, condType string,
	status metav1.ConditionStatus, reason, message string) {
	now := metav1.Now()
	for i, c := range policy.Status.Conditions {
		if c.Type == condType {
			policy.Status.Conditions[i].Status = status
			policy.Status.Conditions[i].Reason = reason
			policy.Status.Conditions[i].Message = message
			policy.Status.Conditions[i].LastTransitionTime = now
			return
		}
	}
	policy.Status.Conditions = append(policy.Status.Conditions, metav1.Condition{
		Type:               condType,
		Status:             status,
		Reason:             reason,
		Message:            message,
		LastTransitionTime: now,
	})
}

// ── Controller setup ──────────────────────────────────────────────────────────

func (r *StartupBoostPolicyReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		// Primary trigger: StartupBoostPolicy create/update/delete.
		For(&startupv1alpha1.StartupBoostPolicy{}).
		// Secondary trigger: Pod state changes in the same namespace.
		// mapPodToPolicy translates the pod event into the policy name so the
		// reconciler runs in response to a pod becoming Ready — no polling needed.
		Watches(
			&corev1.Pod{},
			handler.EnqueueRequestsFromMapFunc(r.mapPodToPolicy),
		).
		Named("startupboostpolicy").
		Complete(r)
}

// mapPodToPolicy is called for every pod event. It returns the reconcile.Request
// for each StartupBoostPolicy in the same namespace whose selector matches the pod.
// The controller-runtime work queue deduplicates concurrent requests for the same
// policy, so a burst of pod events results in at most one reconcile call per policy.
func (r *StartupBoostPolicyReconciler) mapPodToPolicy(
	ctx context.Context, obj client.Object,
) []reconcile.Request {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return nil
	}

	policyList := &startupv1alpha1.StartupBoostPolicyList{}
	if err := r.List(ctx, policyList, client.InNamespace(pod.Namespace)); err != nil {
		return nil
	}

	var requests []reconcile.Request
	for _, policy := range policyList.Items {
		sel, err := metav1.LabelSelectorAsSelector(&policy.Spec.Selector)
		if err != nil {
			continue
		}
		if sel.Matches(labels.Set(pod.Labels)) {
			requests = append(requests, reconcile.Request{
				NamespacedName: types.NamespacedName{
					Name:      policy.Name,
					Namespace: policy.Namespace,
				},
			})
		}
	}
	return requests
}
