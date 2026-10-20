LOCAL_IMAGE ?= startup-boost-operator:local
REMOTE_IMAGE ?= ghcr.io/graz-dev/startup-boost-operator:sha-$(shell git rev-parse --short HEAD)
CLUSTER   ?= cpu-burst-lab
NAMESPACE ?= cpu-burst-operator
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

deploy: ## Install the operator (CRD, RBAC, manager) using the pinned GHCR image
	kubectl apply --server-side -k .
	@echo "Operator installed. Run ./lab.sh operator from the repository root."

deploy-local: kind-load ## Build locally, load into kind, then install (offline / dev use)
	kubectl apply --server-side -k .
	kubectl set image deployment/startup-boost-operator manager=$(LOCAL_IMAGE) -n $(NAMESPACE)
	kubectl patch deployment startup-boost-operator -n $(NAMESPACE) \
	  -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","imagePullPolicy":"Never"}]}}}}'

undeploy: ## Remove all manifests and the CRD from the cluster
	kubectl delete -k . --ignore-not-found
	kubectl delete crd startupboostpolicies.startup.boost.io --ignore-not-found

status: ## Show policies and the resources of the managed Pods
	@kubectl get sbp -A -o wide 2>/dev/null || echo "(no policies)"
