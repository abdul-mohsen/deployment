# Plan: ZATCA Daemon Deployment Service

1. Add the focused shell contract test first and record its expected red result
   on `aea7b6e`.
2. Add the daemon compose overlay with exact T008 runtime variables, persistent
   XML/JetStream mounts, NATS port, restart policy, and authenticated healthcheck.
3. Add the validated `setup-zatca-daemon.sh` command and `deployctl setup zatca`
   mapping; make `restart-stack.sh` manage the service when enabled.
4. Update the backend tenant NATS fallback and the legacy NATS setup guard so
   enabled deployments have one broker.
5. Add configuration examples, DB grant/SDK/runtime documentation, and runbook
   commands without secrets.
6. Run shell syntax checks, focused contract tests, existing shell tests, and
   dashboard Go build/vet/test.
7. Review the diff for scope, credential leakage, stale status, and regression;
   run convergence checks and create one isolated commit.

## Implementation decisions

- Use a compose overlay rather than changing the dashboard's required base
  environment.
- Keep daemon activation explicit with `ZATCA_DAEMON_ENABLED=1`.
- Use operator-provided `ZATCA_DAEMON_IMAGE` and runtime secrets.
- Preserve `setup-nats.sh` for installations that have not enabled the daemon.
