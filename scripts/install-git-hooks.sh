#!/usr/bin/env bash
# Run once after cloning. Wires the repo's .githooks/ as the active hooks dir.
set -e
git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true
echo "[+] git hooks installed (core.hooksPath=.githooks)"
