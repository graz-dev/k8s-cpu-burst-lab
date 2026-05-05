# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM golang:1.23-alpine AS builder

WORKDIR /workspace

# Copy module definition first, then source — so dependency resolution
# is cached separately from code changes.
COPY go.mod ./
COPY cmd/    cmd/
COPY api/    api/
COPY internal/ internal/

# GONOSUMDB=* and -mod=mod let the builder fetch transitive deps without
# a pre-generated go.sum file in the repository.
RUN GONOSUMDB='*' GOFLAGS='-mod=mod' go mod download

# Static binary — no CGO, no libc dependency in the final image.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS='-mod=mod' \
    go build -a -ldflags="-s -w" -o manager ./cmd/main.go

# ── Stage 2: minimal runtime image ────────────────────────────────────────────
# distroless/static has no shell, no package manager, no known CVEs.
FROM gcr.io/distroless/static:nonroot

LABEL org.opencontainers.image.source="https://github.com/graz-dev/k8s-cpu-burst-lab"
LABEL org.opencontainers.image.description="StartupBoostPolicy operator — in-place CPU resize for JVM startup"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /
COPY --from=builder /workspace/manager .
USER 65532:65532

ENTRYPOINT ["/manager"]
