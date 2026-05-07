# =============================================================================
# Dokku Dashboard — runtime image
#
# This Dockerfile expects ./bin/dashboard to be a Linux/amd64 static binary
# already built on the host. Build it with:
#
#   GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
#     go build -ldflags="-s -w" -o bin/dashboard .
#
# (The Makefile / Build-And-Run helpers do this for you.) Building the binary
# on the host avoids running `apk add` inside Docker, which fails behind
# corporate TLS-intercepting proxies that block Alpine/apt mirrors.
# =============================================================================
FROM docker:27-cli
WORKDIR /app
COPY bin/dashboard /app/dashboard
EXPOSE 8080
ENTRYPOINT ["/app/dashboard"]
