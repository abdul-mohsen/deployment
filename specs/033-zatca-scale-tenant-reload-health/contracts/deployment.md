# T033 Deployment Contract

## Tenant create/reload contract

When the daemon is enabled, `create-tenant.sh` must:

1. write or re-enable the configured master `tenant` row;
2. read back the exact tenant/database row with `enabled=1`;
3. invoke `reload-zatca-daemon.sh` after tenant provisioning;
4. wait for the existing authenticated `/healthz` readiness contract; and
5. verify the `ZATCA` JetStream stream and configured pending thresholds.

When the daemon is disabled, step 3 onward is a no-op and the T009 legacy
deployment path remains unchanged.

## Compose contract

The existing `zatca-daemon` service must retain:

- profile `zatca`;
- operator-supplied image and credentials;
- embedded NATS client port and loopback monitor port;
- persistent XML and JetStream volumes;
- `restart: unless-stopped`; and
- authenticated `/healthz` healthcheck.

It additionally maps the following finite host inputs to daemon environment
variables:

- `ZATCA_MAX_WORKERS_PER_TENANT` → `MAX_WORKERS_PER_TENANT`;
- `ZATCA_MAX_WORKERS_PER_BRANCH` → `MAX_WORKERS_PER_BRANCH`;
- `ZATCA_MAX_PENDING` → `MAX_PENDING`; and
- `ZATCA_MAX_ACK_PENDING` → `MAX_ACK_PENDING`.

## Queue-health output contract

`health-zatca-daemon.sh --json` emits a safe JSON object containing:

```json
{
  "status": "healthy",
  "stream": "ZATCA",
  "stream_messages": 0,
  "consumer_count": 1,
  "pending": 0,
  "ack_pending": 0,
  "redelivered": 0,
  "max_pending": 1000,
  "max_ack_pending": 100,
  "limits_ok": true
}
```

The numeric values are examples of shape only; tests and documentation must
not commit or require a particular live queue count.

## Security contract

Monitor authentication is read from existing operator configuration. No
password, encryption key, OTP, DB URL, or raw monitor response may appear in
health output, test fixtures, or committed templates.
