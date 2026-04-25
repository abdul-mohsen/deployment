# =============================================================================
# Frontend Dockerfile — multi-stage Go build
# =============================================================================
# Build:  docker build -t youruser/web:dev .
# Run:    docker run --env-file .env -p 8080:80 youruser/web:dev
# =============================================================================

FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app/server ./cmd/server

FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S app && adduser -S app -G app

WORKDIR /app
COPY --from=builder /app/server .

USER app
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --spider -q http://localhost:80/ || exit 1

ENTRYPOINT ["./server"]
