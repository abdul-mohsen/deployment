# STATUS

## Completed

- Requirements, research, design, plan, task graph, and spec artifacts created
  for the deployment-only T009 lane.
- Baseline confirmed clean at `aea7b6e` on `fix/zatca/c1-daemon-service`.
- Focused contract test added.
- Focused contract test run red: `FAIL: ZATCA daemon compose template is missing`.
- Added the daemon compose overlay, lifecycle script, deployctl mapping, NATS
  ownership guard, restart ordering, configuration examples, and runbook docs.
- Focused contract test is green.
- Docker Compose interpolation check is green with placeholders.
- Full shell suite is green; dashboard Go build, vet, and tests are green when
  invoked with the installed Go 1.26.4 toolchain.

## In Progress

- T009-8: isolated commit is the final remaining action.

## Blocked

- None. The approved T008 image registry/tag remains an operator input, not a
  code blocker.

## Backlog

- None.

## Risks

- Existing hosts may still run the legacy `nats` container on port 4222; the
  enabled daemon path must fail clearly rather than run two brokers.
- The dependent image must contain the T008 authenticated monitor `/healthz`
  endpoint and the approved Java/Fatoora runtime.

## Next Actions

- Commit the reviewed deployment-only diff; no push or PR creation.
