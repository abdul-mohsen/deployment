# T033 Implementation Plan

## Approach

1. Add the T033 feature artifacts and a focused static deployment contract.
2. Run the new contract against e289a72 and preserve the expected red result.
3. Add a scoped queue-health command that reuses the authenticated T009
   monitor and reports stream/consumer/pending state.
4. Add an idempotent daemon reload helper and invoke it from tenant creation
   only after registry read-back succeeds and only when the daemon is enabled.
5. Forward and validate finite worker/backlog settings in the existing daemon
   compose overlay without changing the T009 command line or credentials.
6. Update operator configuration and deployment runbooks.
7. Run shell syntax, focused and existing deployment tests, dashboard Go
   tests/vet/build, convergence checks, self-review, and an isolated commit.

## Files

- `scripts/create-tenant.sh`
- `scripts/reload-zatca-daemon.sh`
- `scripts/health-zatca-daemon.sh`
- `scripts/setup-zatca-daemon.sh`
- `scripts/deployctl.sh`
- `dashboard/docker-compose.zatca.yml`
- `config.env.example`, `install.env.example`
- `README.md`, `REQUIREMENTS.md`, `dashboard/README.md`,
  `templates/README.md`
- `scripts/tests/test-zatca-scale.sh`
- `specs/033-zatca-scale-tenant-reload-health/*`

## Validation gates

- Red: `bash scripts/tests/test-zatca-scale.sh` before production edits.
- Syntax: `bash -n` on changed scripts and all deployment scripts.
- Targeted: T033 contract plus `test-create-tenant.sh`,
  `test-zatca-daemon.sh`, and `test-restart-stack.sh`.
- Dashboard: `(cd dashboard && go test ./...)`, `go vet ./...`,
  `go build ./...`.
- Static compose interpolation with placeholders when Docker is available.
- Final: `git diff --check`, status/diff review, convergence checklist, and
  one commit with the required co-author trailer; no push/PR.

## Decisions and trade-offs

- Controlled recreation is used because the T009 image has no reload API.
- Queue health is additive to `/healthz`; `/healthz` remains the liveness
  contract and `/jsz` supplies operational backlog evidence.
- Worker limits are forwarded as additive image inputs. The deployment does
  not pretend a T009 image enforces unknown variables; the current sequential
  worker behavior and health thresholds remain the safe compatibility floor.
