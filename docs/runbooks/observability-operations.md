# Observability operations runbook

This runbook covers the operator-only Grafana, Loki, Prometheus, and Alloy
profile. It does not grant access to tenant application logs and does not
replace the deployment or database backup procedures.

## Start and verify

From the deployment checkout:

```sh
cd dashboard
cp observability/.env.example observability/.env
# Set OBS_GRAFANA_ADMIN_PASSWORD and protect the file (0600).
docker compose --env-file observability/.env \
  -f docker-compose.observability.yml --profile observability up -d
docker compose --env-file observability/.env \
  -f docker-compose.observability.yml --profile observability ps
```

Verify all services are running before using the dashboards:

```sh
docker compose --env-file observability/.env \
  -f docker-compose.observability.yml --profile observability logs --tail=80 \
  docker-socket-proxy docker-api-filter alloy loki prometheus grafana
```

Open Grafana through a local SSH tunnel, not a public port:

```sh
ssh -N -L 3000:127.0.0.1:3000 operator@server
```

Then browse to `http://127.0.0.1:3000` and confirm the two dashboards are in
the `Ifritah Operations` folder. The default admin password is not acceptable
for an operational installation.

## Health checks

1. In **Ifritah Operations Overview**, confirm Alloy, Loki, Prometheus, and
   Grafana are all `UP`.
2. Open the **Ifritah Log Operations** dashboard and confirm recent
   `app="ifritah-dashboard"` events arrive.
3. In Grafana Alerting, confirm the three provisioned rules are evaluating.
4. If a contact point is installed, use Grafana's built-in contact-point test
   and record the delivery result in the change ticket.

Do not expose Prometheus, Loki, Alloy, the Docker API filter, or the Grafana
port through host firewall rules. Grafana is already loopback-bound by Compose.

## Retention and disk pressure

The starting profile retains Loki data for 7 days and Prometheus data for
7 days or 5 GiB. Check the named volume usage during routine maintenance:

```sh
docker system df -v
docker volume inspect ifritah-observability-loki \
  ifritah-observability-prometheus ifritah-observability-grafana
```

If the host is approaching its disk budget:

1. Capture the current alert and incident evidence.
2. Lower `OBS_PROMETHEUS_RETENTION_TIME` or
   `OBS_PROMETHEUS_RETENTION_SIZE` in `observability/.env`.
3. Recreate only Prometheus; do not delete volumes during an incident.
4. Reduce Loki's `retention_period` only through a reviewed config change.
5. Recheck free space and alert delivery.

Never delete the Alloy volume casually: it stores Docker log positions and
deleting it can replay old dashboard logs.

## Safe restart and recovery

For a routine config change:

```sh
docker compose --env-file observability/.env \
  -f docker-compose.observability.yml --profile observability up -d \
  --force-recreate grafana prometheus alloy
```

If Grafana is unhealthy, keep Loki and Prometheus running while collecting
their logs, then recreate Grafana. If the collector is unhealthy, inspect the
Docker API filter and socket proxy first; do not mount the host Docker socket
directly into Alloy.

If the whole profile must be stopped:

```sh
docker compose --env-file observability/.env \
  -f docker-compose.observability.yml --profile observability down
```

Do not add `--volumes` unless data loss is approved and the retention impact
is recorded.

## Credential rotation

Rotate the Grafana admin password by updating the protected
`observability/.env` file and recreating Grafana. Rotate SMTP passwords or
Slack webhook URLs in the operator secret store, update the environment, and
recreate Grafana. The ignored contact-point file may contain destination
configuration, so keep its mode restrictive and never commit it.

## Evidence and escalation

For an incident, record:

- UTC incident start and end;
- affected component and container state;
- alert name, severity, and first/last firing time;
- dashboard request IDs and stable `error_type`/`error_code` values;
- the exact config revision used;
- whether any volume or retention change was made.

Do not copy raw request bodies, cookies, authorization headers, tenant
secrets, or unbounded error strings into the incident ticket.
