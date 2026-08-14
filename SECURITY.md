# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Preferred: use GitHub's private vulnerability reporting on this repository
(Security tab → "Report a vulnerability"). It creates a private draft
advisory and notifies the maintainer.

Alternative: email the maintainer listed in `install.env` under `ACME_EMAIL`,
with subject prefix `[security]`.

Include:

- What you did (steps to reproduce)
- What happened (actual output / behavior)
- What should have happened (expected behavior)
- Version / commit SHA where you observed it
- Any partial fix ideas you already have

Expect an acknowledgement within 5 business days. Fixes ship on a
rolling basis; there is no fixed embargo window.

## Supported versions

Only `main` receives security fixes. If you are running a fork or a
pinned older tag, upgrade to `main` first.

## Scope

In scope:

- The dashboard binary (`dashboard/`) — Go server, its HTTP handlers,
  session handling, script-runner sidecar surface
- Provisioning scripts under `scripts/` — command construction,
  argument handling, sensitive-data logging
- CI workflows under `.github/workflows/` — supply-chain, secret
  handling

Out of scope (do not report):

- Operator misconfiguration (weak `MYSQL_ROOT_PASSWORD`, exposed
  `DOKKU_PORT`, world-writable `config.env`, etc.)
- Vulnerabilities in Dokku itself — report those upstream to
  https://github.com/dokku/dokku/security
- Third-party image contents (backend, frontend, MySQL) unless the
  dashboard shells them out in an unsafe way

## Automated scanning

This repo runs, on every push to `main` and on every PR:

- **CodeQL** — Go + JavaScript SAST (`.github/workflows/codeql.yml`)
- **govulncheck** — Go stdlib and module CVEs
  (`.github/workflows/govulncheck.yml`), also nightly
- **gosec** — Go static analysis for common weaknesses
  (`.github/workflows/gosec.yml`)
- **Dependabot** — weekly PRs for outdated Go / GitHub Actions / npm
  dependencies (`.github/dependabot.yml`)

Findings surface in the repo's Security tab. Contributors are expected
to keep new PRs green — do not merge a PR that introduces a HIGH or
CRITICAL finding without an explanation in the PR body.
