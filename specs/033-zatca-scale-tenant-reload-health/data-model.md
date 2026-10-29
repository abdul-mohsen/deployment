# T033 Data Model

## Deployment configuration

| Field | Source | Rule |
|---|---|---|
| `ZATCA_DAEMON_ENABLED` | existing config | `0`, `1`, `true`, or `yes`; only enabled values trigger reload. |
| `ZATCA_MAX_WORKERS_PER_TENANT` | new optional config | finite positive integer; default `1`. |
| `ZATCA_MAX_WORKERS_PER_BRANCH` | new optional config | finite positive integer; default `1`. |
| `ZATCA_MAX_PENDING` | new optional config | finite positive integer; default `1000`. |
| `ZATCA_MAX_ACK_PENDING` | new optional config | finite non-negative integer; default `100`. |
| `NATS_MONITOR_PORT` | existing config | monitor host port; default `8222`; loopback-only in Compose. |
| `ZATCA_MONITOR_PASSWORD` | existing config | operator-supplied secret; never emitted by health output. |

## Tenant registration

| Field | Source | Rule |
|---|---|---|
| `name` | normalized tenant name | exact row selected for read-back. |
| `db_name` | `tenant_<name>` convention | exact row selected for read-back. |
| `enabled` | master registry | must equal `1` before reload. |

## Queue-health snapshot

| Field | Source | Rule |
|---|---|---|
| `stream` | NATS `/jsz` stream detail | must be `ZATCA`. |
| `stream_messages` | stream state | non-fabricated current message count. |
| `consumer_count` | stream consumer detail | zero is valid only when no tenant consumer exists. |
| `pending` | sum of consumer `num_pending` | must not exceed `ZATCA_MAX_PENDING`. |
| `ack_pending` | sum of consumer `num_ack_pending` | must not exceed `ZATCA_MAX_ACK_PENDING`. |
| `redelivered` | sum of consumer `num_redelivered` | informational, safe aggregate. |
| `limits_ok` | threshold comparison | false causes a non-zero health result. |
