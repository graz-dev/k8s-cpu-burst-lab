LOCAL_IMAGE ?= startup-boost-operator:local
REMOTE_IMAGE ?= ghcr.io/graz-dev/startup-boost-operator:latest
CLUSTER   ?= cpu-burst-lab
NAMESPACE ?= cpu-burst-demo
GOARCH    := $(shell uname -m | sed 's/x86_64/amd64/;s/arm64/arm64/')

.PHONY: help deps build test docker-build kind-load publish deploy deploy-local undeploy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "}{printf "  %-15s %s\n", $$1, $$2}'

deps: ## Download Go module dependencies (required once after cloning)
	go mod tidy

build: ## Compile the manager binary locally
	CGO_ENABLED=0 go build -o bin/manager ./cmd/main.go

test: ## Run unit tests
	go test ./... -v

docker-build: ## Build the container image (local tag)
	docker build --build-arg TARGETARCH=$(GOARCH) -t $(LOCAL_IMAGE) .

kind-load: docker-build ## Build and load the local image into the kind cluster
	kind load docker-image $(LOCAL_IMAGE) --name $(CLUSTER)
	@echo "✅  Image loaded: $(LOCAL_IMAGE)"

publish: ## Build and push to GHCR (requires: docker login ghcr.io)
	docker build -t $(REMOTE_IMAGE) .
	docker push $(REMOTE_IMAGE)
	@echo "✅  Image pushed: $(REMOTE_IMAGE)"

deploy: ## Install operator (CRD + RBAC + controller + app) using the public GHCR image
	kubectl apply --server-side -k .
	@echo ""
	@echo "✅  Operator installed. Now create a StartupBoostPolicy:"
	@echo "    kubectl apply -f config/samples/startupboostpolicy.yaml"
	@echo ""
	@echo "    kubectl get sbp -n $(NAMESPACE)"
	@echo "    kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=startup-boost-operator -f"

deploy-local: kind-load ## Build locally, load into kind, then install (offline / dev use)
	kubectl apply --server-side -k .
	kubectl set image deployment/startup-boost-operator manager=$(LOCAL_IMAGE) -n $(NAMESPACE)
	kubectl patch deployment startup-boost-operator -n $(NAMESPACE) \
	  -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","imagePullPolicy":"Never"}]}}}}'
	@echo ""
	@echo "✅  Operator installed (local image). Now create a StartupBoostPolicy:"
	@echo "    kubectl apply -f config/samples/startupboostpolicy.yaml"

undeploy: ## Remove all manifests and the CRD from the cluster
	kubectl delete -k . --ignore-not-found
	kubectl delete crd startupboostpolicies.startup.boost.io --ignore-not-found

status: ## Show current policy and pod state
	@echo "=== StartupBoostPolicy ==="
	@kubectl get sbp -n $(NAMESPACE) -o wide 2>/dev/null || echo "(not found)"
	@echo ""
	@echo "=== Pod resources ==="
	@kubectl get pod -n $(NAMESPACE) -l app.kubernetes.io/name=petclinic \
	  -o jsonpath='{range .items[*]}pod={.metadata.name} cpu_req={.spec.containers[0].resources.requests.cpu} allocated={.status.containerStatuses[0].allocatedResources.cpu} restarts={.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null || true
