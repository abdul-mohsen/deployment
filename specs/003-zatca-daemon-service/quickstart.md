# Quickstart: Validate the ZATCA Daemon Deployment

## Prerequisites

- Docker Engine and Compose plugin on the deployment host.
- An approved T008 daemon image containing the Java/Fatoora SDK runtime.
- A config file with the required non-secret image, database, path, encryption,
  and monitor settings described in the root README.
- A MySQL daemon account with the documented master/tenant grants.
- The legacy standalone `nats` container stopped before enabling the daemon if
  it owns the configured NATS port.

## Contract validation

From the repository root:

```bash
bash scripts/tests/test-zatca-daemon.sh
```

Expected result: `PASS: ZATCA daemon deployment contract`.

## Start and verify

```bash
sudo ./scripts/deployctl.sh --config /opt/deployment/config.env setup zatca
docker inspect --format '{{.State.Health.Status}}' zatca-daemon
```

Expected result: the container reaches `healthy`. The service publishes the
configured NATS client port for tenant containers and keeps monitor access
loopback-bound.

## Restart validation

```bash
sudo ./scripts/deployctl.sh --config /opt/deployment/config.env stack restart --env all
```

With `ZATCA_DAEMON_ENABLED=1`, the daemon is stopped before Dokku and started
before dashboards. With the flag unset/disabled, existing deployment behavior
is unchanged.

## Repository checks

```bash
bash -n scripts/setup-zatca-daemon.sh scripts/deployctl.sh scripts/restart-stack.sh
(cd dashboard && go test ./...)
(cd dashboard && go vet ./...)
(cd dashboard && go build ./...)
```
