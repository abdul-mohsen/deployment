#!/bin/bash
# Remove leftover Docker Compose + Traefik files from the old deployment approach.
# Run this once after switching to Dokku.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

echo "Cleaning up old Docker Compose + Traefik files..."

rm -rf "$BASE_DIR/traefik"
rm -rf "$BASE_DIR/loki"
rm -rf "$BASE_DIR/promtail"
rm -rf "$BASE_DIR/grafana"
rm -rf "$BASE_DIR/templates"
rm -f  "$BASE_DIR/docker-compose.yml"
rm -f  "$BASE_DIR/.env.example"

echo "Done. Old files removed."
