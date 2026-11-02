# =============================================================================
# Backend Dockerfile — multi-stage Go build. The tenant DB is built by goose:
# /app/migrate runs `up`, and deployment runs it before each release is deployed.
# =============================================================================
# Build:  docker build --build-arg APP_VERSION=v0.0.1 -t youruser/api:v0.0.1 .
# Run:    docker run --env-file .env -p 3000:3000 youruser/api:v0.0.1
# =============================================================================

# ---- Build stage ----
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app/server ./cmd/server
# Goose runner: `/app/migrate up` builds the tenant DB; deployment runs it before each release.
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app/migrate ./cmd/migrate

# ---- Runtime stage ----
FROM alpine:3.20

ARG APP_VERSION=v0.0.1
ENV APP_VERSION=$APP_VERSION
LABEL org.opencontainers.image.version=$APP_VERSION

RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S app && adduser -S app -G app

WORKDIR /app

COPY --from=builder /app/server .
COPY --from=builder /app/migrate .
COPY --from=builder /src/migrations /app/migrations

RUN mkdir -p /app/uploads /app/data && chown -R app:app /app

USER app
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --spider -q http://localhost:3000/api/health || exit 1

ENTRYPOINT ["./server"]
