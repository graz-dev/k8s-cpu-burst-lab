# ── Stage 1: build ────────────────────────────────────────────────────────────
# BUILDPLATFORM is the CI runner's native platform (always amd64 on GitHub Actions).
# Running the builder stage natively and cross-compiling via GOARCH is ~10x faster
# than QEMU emulation. The ARG default makes legacy `docker build` work unchanged.
ARG BUILDPLATFORM=linux/amd64
FROM --platform=${BUILDPLATFORM} golang:1.23-alpine AS builder

ARG TARGETOS=linux
ARG TARGETARCH=amd64

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

# Static binary — TARGETOS/TARGETARCH are set by Docker Buildx for each platform.
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOFLAGS='-mod=mod' \
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
