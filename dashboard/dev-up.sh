#!/usr/bin/env bash
# Builds the Linux binary on the host and rebuilds the dev container.
set -euo pipefail

cd "$(dirname "$0")"

export GOOS=linux
export GOARCH=amd64
export CGO_ENABLED=0

mkdir -p bin
go build -ldflags="-s -w" -trimpath -o bin/dashboard .

docker compose -f docker-compose.dev.yml up -d --build
