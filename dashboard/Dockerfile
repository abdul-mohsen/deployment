# =============================================================================
# Dokku Dashboard — multi-stage build with vendored dependencies.
#
# All Go dependencies are vendored (vendor/ directory).
# docker build needs NO internet access for Go packages.
#
# Stage 1 (builder):  golang:1.25-alpine compiles the binary from vendor/.
# Stage 2 (runtime):  alpine:3.20 (~12MB) + docker CLI + compiled binary.
#                     Total: ~65MB vs 278MB for docker:27-cli.
# =============================================================================

# ── Stage 1: compile ─────────────────────────────────────────────────────────
FROM golang:1.25-alpine AS builder

WORKDIR /src
COPY . .

# -mod=vendor: use the checked-in vendor/ directory — no network calls needed.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -mod=vendor -ldflags="-s -w" -trimpath -o /dashboard .

# ── Stage 2: docker CLI (extract binary only) ────────────────────────────────
FROM docker:27-cli AS docker-bin

# ── Stage 3: minimal runtime ─────────────────────────────────────────────────
FROM alpine:3.20

# Copy CA certs from builder (no apk network call needed).
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# Docker CLI — needed to run "docker exec <dokku> dokku ..."
COPY --from=docker-bin /usr/local/bin/docker /usr/local/bin/docker

# Dashboard binary.
COPY --from=builder /dashboard /app/dashboard

WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["/app/dashboard"]
