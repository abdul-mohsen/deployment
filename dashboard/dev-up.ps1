# Builds the Linux binary on the host and rebuilds the dev container.
$ErrorActionPreference = 'Stop'
$env:GOOS = 'linux'
$env:GOARCH = 'amd64'
$env:CGO_ENABLED = '0'
New-Item -ItemType Directory -Force -Path bin | Out-Null
go build -ldflags="-s -w" -trimpath -o bin/dashboard .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
docker compose -f docker-compose.dev.yml up -d --build
