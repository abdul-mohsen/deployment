# Design: ZATCA Daemon Deployment Service

## Architecture

```text
Dokku backend containers
        │  NATS_URL = nats://host.docker.internal:${NATS_PORT}
        ▼
host-published port 4222 ──► zatca-daemon container
                              ├─ embedded NATS + JetStream (/data/nats)
                              ├─ master/tenant MySQL connections
                              ├─ signed XML volume (/data/zatca-xml)
                              └─ authenticated monitor /healthz (:8222)
```

The service is defined in `dashboard/docker-compose.zatca.yml`. The existing
dashboard compose profiles remain unchanged. `scripts/setup-zatca-daemon.sh`
starts and verifies the overlay; `scripts/restart-stack.sh` includes it when
`ZATCA_DAEMON_ENABLED=1`. `deployctl.sh setup zatca` is the stable operator
entrypoint.

## Configuration boundary

Deployment configuration uses prefixed host-level names:

- `ZATCA_DAEMON_IMAGE`: approved T008 image reference.
- `ZATCA_DB_USER` / `ZATCA_DB_PASSWORD`: dedicated runtime account.
- `ZATCA_ADMIN_DB_USER` / `ZATCA_ADMIN_DB_PASSWORD`: optional onboarding
  account.
- `ZATCA_ENCRYPT_KEY`: key for encrypted branch credentials.
- `ZATCA_MONITOR_PASSWORD`: monitor Basic Auth password.
- `NATS_PORT`, `NATS_MONITOR_PORT`, `ZATCA_NATS_URL`: shared queue endpoint.
- `ZATCA_XML_ROOT`, `ZATCA_NATS_DATA_ROOT`: persistent host paths.
- `ZATCA_SMTP_*`: optional alert delivery inputs.

The compose overlay maps these to the exact T008 container contract. Required
values are validated by the setup script before Compose starts; no sample
secret is committed.

## Service lifecycle

1. `setup-zatca-daemon.sh` loads the selected config file and validates the
   image, DB password, encryption key, and monitor password.
2. It creates the configured persistent host directories.
3. It starts the overlay with `restart: unless-stopped`.
4. It waits for the container's authenticated monitor healthcheck to become
   `healthy`, printing bounded logs on failure.
5. `restart-stack.sh` stops the daemon before Dokku and starts it before the
   dashboard when the daemon is enabled.

The legacy `setup-nats.sh` command becomes a compatibility no-op when the
daemon is enabled, preventing two JetStream owners from competing for the
configured port. It retains its prior standalone behavior when the daemon is
disabled.

## Health/readiness

The compose healthcheck performs an authenticated GET to
`http://127.0.0.1:8222/healthz` using the container's `MONITOR_PASS`. The host
monitor port is bound to loopback only. The NATS client port is published for
Dokku tenant containers because they reach host services through
`host.docker.internal`.

## Failure handling and rollback

- Missing required configuration fails before container creation.
- A host port collision fails Compose rather than silently launching a second
  broker.
- Existing dashboard/Dokku services are not changed when the daemon is
  disabled.
- Removing the daemon container does not remove its bind-mounted XML or
  JetStream data.
- Rollback is the normal git revert; operators can disable
  `ZATCA_DAEMON_ENABLED` and continue using the legacy standalone NATS path
  while the daemon change is investigated.

## Security

- No credentials are placed in images, YAML literals, tests, or documentation.
- The deployment admin account is not injected into the daemon.
- NATS monitoring is loopback-bound and password-protected.
- The NATS client port follows the existing host-service exposure model; host
  firewall policy remains the operator's responsibility.

## Requirement traceability

| Requirement | Design element |
|---|---|
| FR-001 | Required image input and named `zatca-daemon` service in compose overlay. |
| FR-002 | Embedded NATS/JetStream, persistent `/data/nats`, host-published client port, tenant `NATS_URL`. |
| FR-003 | Shared MySQL host/port/master DB plus dedicated runtime/admin credentials. |
| FR-004 | Persistent `ZATCA_XML_ROOT:/data/zatca-xml` bind mount. |
| FR-005 | `restart: unless-stopped` and restart-stack ordering. |
| FR-006 | Authenticated monitor `/healthz` healthcheck and loopback monitor binding. |
| FR-007 | Overlay and explicit enable flag preserve legacy dashboard/NATS behavior. |
| FR-008 | Focused `test-zatca-daemon.sh`, red on base and green after implementation. |
| FR-009 | Root README, template README, and config examples document image/SDK/runtime inputs and grants. |
