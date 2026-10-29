# Deployment Contract: ZATCA Daemon

## Compose service

The service name is `zatca-daemon`. It must:

- use the operator-supplied `ZATCA_DAEMON_IMAGE`;
- use `restart: unless-stopped`;
- publish the embedded NATS client port configured by `NATS_PORT`;
- bind `ZATCA_XML_ROOT` to `/data/zatca-xml`;
- bind `ZATCA_NATS_DATA_ROOT` to `/data/nats`;
- map `MYSQL_HOST`, `MYSQL_PORT`, and `MYSQL_MASTER_DB`;
- map dedicated runtime and optional onboarding DB credentials;
- require `ZATCA_ENCRYPT_KEY` and `ZATCA_MONITOR_PASSWORD`;
- expose monitor health only through loopback and an authenticated `/healthz`.

## Tenant contract

`create-tenant.sh` must set:

```text
NATS_URL = NATS_URL override
        or ZATCA_NATS_URL
        or nats://host.docker.internal:4222
```

This preserves the existing standalone NATS default while allowing enabled
daemon deployments to select a non-default host port.

## Lifecycle contract

`deployctl setup zatca` validates inputs, creates persistent directories,
starts the service, and waits for `healthy`. `stack restart` includes the
daemon only when `ZATCA_DAEMON_ENABLED=1`.
