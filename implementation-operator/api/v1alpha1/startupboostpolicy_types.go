package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// StartupBoostPolicySpec declares which pods to manage and what CPU they should
// run at after their startup burst is complete.
type StartupBoostPolicySpec struct {
	// Selector identifies which pods in this namespace are managed by the policy.
	// Pods must also carry resizePolicy.restartPolicy=NotRequired on the target
	// container, otherwise the kubelet will restart the container on resize.
	Selector metav1.LabelSelector `json:"selector"`

	// Containers lists one entry per container to resize after startup.
	// +kubebuilder:validation:MinItems=1
	Containers []ContainerBoostSpec `json:"containers"`

	// StabilizationSeconds is the number of seconds to wait after the pod
	// becomes Ready before submitting the resize patch. Default: 0 (immediate).
	// Use a small value (e.g. 10) if your readiness probe fires before the JVM
	// has fully warmed up in your environment.
	// +kubebuilder:default=0
	// +optional
	StabilizationSeconds int32 `json:"stabilizationSeconds,omitempty"`
}

// ContainerBoostSpec specifies the steady-state CPU for one container.
type ContainerBoostSpec struct {
	// Name is the container name within the pod spec.
	Name string `json:"name"`

	// SteadyCPU is the CPU quantity to resize to once the pod is Ready.
	// Must be a valid Kubernetes resource quantity (e.g. "300m", "0.3").
	// Only CPU requests and limits are changed; memory is left intact to avoid
	// flipping the pod's QoS class from Burstable to Guaranteed.
	SteadyCPU string `json:"steadyCPU"`
}

// Phase represents the lifecycle state of a single pod's boost.
type Phase string

const (
	// PhaseBurst means the pod is still starting up; burst CPU is allocated.
	PhaseBurst Phase = "Burst"
	// PhaseReady means the pod became Ready; the resize patch is being applied.
	PhaseReady Phase = "Ready"
	// PhaseSteady means the in-place resize completed; steady-state CPU is allocated.
	PhaseSteady Phase = "Steady"
	// PhaseFailed means the resize patch was rejected; the pod keeps burst CPU.
	PhaseFailed Phase = "Failed"
)

// PodBoostStatus tracks the resize lifecycle for a single pod.
type PodBoostStatus struct {
	// Name is the pod name.
	Name string `json:"name"`

	// Phase is the current lifecycle state.
	Phase Phase `json:"phase"`

	// ResizedAt is the timestamp when the resize patch was accepted by the API server.
	// +optional
	ResizedAt *metav1.Time `json:"resizedAt,omitempty"`

	// SteadyCPU is the CPU value the pod was resized to.
	// +optional
	SteadyCPU string `json:"steadyCPU,omitempty"`

	// Message contains additional context (e.g. an error reason on PhaseFailed).
	// +optional
	Message string `json:"message,omitempty"`
}

// StartupBoostPolicyStatus reflects what the controller has observed and done.
type StartupBoostPolicyStatus struct {
	// BoostedPods lists the current resize state for every pod matched by the selector.
	// +optional
	BoostedPods []PodBoostStatus `json:"boostedPods,omitempty"`

	// Conditions holds standard Kubernetes condition objects for the policy itself.
	// +optional
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=sbp,scope=Namespaced
// +kubebuilder:printcolumn:name="Selector",type=string,JSONPath=`.spec.selector.matchLabels`
// +kubebuilder:printcolumn:name="SteadyCPU",type=string,JSONPath=`.spec.containers[0].steadyCPU`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// StartupBoostPolicy is the CRD that configures the in-place CPU resize pattern
// for pods that need extra CPU during JVM (or any runtime) startup.
//
// Create one policy per workload (or share one across workloads with a broad
// selector). The controller watches pods in the same namespace and applies the
// resize as soon as each pod's Ready condition becomes True.
type StartupBoostPolicy struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   StartupBoostPolicySpec   `json:"spec,omitempty"`
	Status StartupBoostPolicyStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// StartupBoostPolicyList contains a list of StartupBoostPolicy.
type StartupBoostPolicyList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []StartupBoostPolicy `json:"items"`
}

func init() {
	SchemeBuilder.Register(&StartupBoostPolicy{}, &StartupBoostPolicyList{})
}
