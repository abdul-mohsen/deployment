FROM golang:1.23.4-alpine@sha256:c23339199a08b0e12032856908589a6d41a0dab141b8b3b21f156fc571a3f1d3 AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN mkdir -p /queue && chown 65532:65532 /queue
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /openobserve-gateway .

FROM scratch
COPY --from=builder /openobserve-gateway /openobserve-gateway
COPY --from=builder --chown=65532:65532 /queue /var/lib/openobserve-gateway
USER 65532:65532
ENTRYPOINT ["/openobserve-gateway"]
