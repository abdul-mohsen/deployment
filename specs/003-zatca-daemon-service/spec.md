# Specification: ZATCA Daemon Deployment Service

## User value

Operators can deploy and restart the ZATCA daemon alongside the existing
Dokku/dashboard platform. Backend tenants publish to the daemon's persistent
JetStream queue, the daemon can read the configured master and tenant
databases, signed XML survives container replacement, and readiness is visible
through an authenticated health contract.

## Scope

This feature changes only the deployment repository. It consumes the approved
T008 daemon image and does not change daemon, backend, or frontend source code.
Legacy standalone NATS remains available when the daemon is not enabled.

## Acceptance scenarios

- With a complete operator config, `setup zatca` starts a named daemon service
  and waits for it to become healthy.
- The service maps persistent XML and JetStream directories, uses the configured
  MySQL host/port/master DB and dedicated daemon account, and publishes the
  NATS client port used by tenants.
- Restarting the stack with daemon enabled stops the daemon before Dokku and
  starts it before dashboards, while the existing disabled path remains intact.
- Missing image or required secret inputs fail before Compose starts.
- The focused shell contract fails on the base commit and passes after the fix.

## Constraints

- No hard-coded credentials, proprietary SDK files, or invoice data.
- No changes to other repositories.
- Existing dashboard, tenant, Dokku, and standalone NATS behavior remains
  compatible when `ZATCA_DAEMON_ENABLED` is unset or disabled.
