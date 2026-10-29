# Requirements: ZATCA Daemon Deployment Service

## Problem

The deployment repository provisions backend and frontend tenant services, but
does not provision the ZATCA daemon that consumes the backend's ZATCA work.
Operators therefore have no first-class, restart-safe deployment contract for
the shared NATS/JetStream queue, tenant/master database access, signed XML
storage, or daemon readiness.

## Goal

Add the ZATCA daemon to the repository's existing deployment service
templates/scripts without changing the existing tenant or dashboard behavior.
The deployment contract must be reproducible from operator-supplied image,
credential, SDK/runtime, database, and storage configuration.

## In scope

- A first-class daemon service in the deployment compose/template path used by
  operators.
- Configuration wiring for the daemon image, NATS/JetStream endpoint and
  persistence, master/tenant MySQL access, encrypted ZATCA credentials, XML
  storage, monitoring, and restart policy.
- Backend-facing NATS URL wiring so backend and daemon use the same queue.
- A readiness/health contract that is testable by the deployment stack.
- Existing deployment command/restart behavior needed to start and verify the
  daemon.
- A focused deployment contract test, proven failing before the fix and
  passing afterward.
- Operator documentation/runbook updates, including required SDK/runtime image
  inputs and secrets without inventing credential values.

## Out of scope

- Changes to the ZATCA daemon source repository or backend/frontend source
  repositories.
- Provider behavior, invoice/XML semantics, onboarding logic, or queue worker
  implementation.
- Creating credentials, SDK files, proprietary artifacts, or invoice data.
- Introducing a second NATS/JetStream service when the daemon already owns the
  embedded JetStream instance.
- Replacing the existing Dokku tenant lifecycle or dashboard control plane.

## User stories

1. As an operator, I can enable the daemon with an approved image and
   operator-provided secrets, and the service starts with the same NATS/JetStream
   endpoint used by backend tenants.
2. As an operator, I can restart the deployment stack and have the daemon,
   backend-facing queue, database connections, and XML volume recover under the
   existing restart policy.
3. As an operator, I can determine whether the daemon is ready through the
   deployment health/readiness contract without inspecting application logs.
4. As a release engineer, I can run a focused deployment contract test that
   detects if the daemon service, required shared resources, or health contract
   disappears.

## Functional requirements

- **FR-001**: The deployment templates expose one named ZATCA daemon service
  using an operator-selected image; no secret or proprietary SDK artifact is
  hard-coded.
- **FR-002**: The daemon service persists its embedded NATS JetStream data and
  exposes the configured NATS client endpoint to backend tenants without
  starting a competing broker.
- **FR-003**: The daemon receives the configured master database and tenant
  database connection inputs, including the configured master database name,
  host, port, runtime user/password, and optional onboarding admin credentials.
- **FR-004**: The daemon receives the configured XML storage directory through a
  persistent volume rooted at the deployment storage contract.
- **FR-005**: The daemon uses an explicit restart policy consistent with the
  existing deployment services.
- **FR-006**: The daemon has a readiness/health check using the runtime's
  documented monitoring/readiness endpoint and does not expose an unauthenticated
  monitoring secret.
- **FR-007**: Existing backend/frontend/dashboard/Dokku deployment behavior is
  preserved; daemon wiring is additive and opt-in through existing configuration
  contracts.
- **FR-008**: The focused deployment contract test fails on the base because the
  daemon service is absent and passes after implementation, covering service
  identity, shared queue/database/storage wiring, restart policy, and health
  contract.
- **FR-009**: README/runbook documentation identifies required daemon image,
  SDK/runtime build inputs, database privileges, encryption/monitoring secrets,
  and storage requirements while leaving values to the operator.

## Non-functional requirements

- Credentials must be supplied through existing env/config files or secret
  stores; tests must use placeholders and must not commit real values.
- Compose/template interpolation must fail clearly when required runtime
  secrets or image inputs are missing.
- Persistent data must survive service recreation.
- The change must be limited to this deployment repository and remain
  independently reviewable.

## Acceptance criteria

1. A deployment contract test is recorded red against `aea7b6e` because no
   daemon service exists.
2. The daemon service is present in the repository's existing service template
   path and has the required shared NATS/JetStream, database, XML, restart, and
   health/readiness contract.
3. Backend tenant configuration points to the same daemon-owned NATS endpoint;
   no second broker is introduced by the deployment repository.
4. Required secrets and runtime/SDK inputs are documented and injected only
   from operator configuration.
5. Shell syntax, focused deployment contract tests, applicable Go tests/vet/build,
   and relevant compose/template checks pass.
6. Existing deployment tests continue to pass.
7. The final change is committed as one isolated PR-ready commit without push
   or PR creation.

## Assumptions

- The daemon image is built and published by the dependent T008 ZATCA lane and
  contains the daemon binary, Java runtime, and approved Fatoora SDK artifact.
- The daemon owns the embedded NATS server/JetStream instance; backend services
  connect to its published NATS client port.
- The deployment host's configured MySQL account is granted the daemon's
  required read/update access to the master registry and tenant databases.
- The existing dashboard compose files and restart script are the deployment
  service entrypoint for long-running control-plane services.

## Risks and unknowns

- The exact image registry/tag is deployment-specific and must remain an
  operator-provided variable.
- The daemon's health endpoint is implemented by the dependent daemon image;
  the deployment contract must use the documented authenticated monitoring
  endpoint available from that image rather than inventing an application API.
- Existing production installations may not yet have a dedicated daemon DB user;
  documentation must make the required grants explicit without silently
  reusing or printing admin credentials.
