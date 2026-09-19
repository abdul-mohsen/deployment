# External uptime monitoring runbook

No provider account or API token is stored in the allowed worktrees. This
runbook is the integration boundary to use once an operator selects an
approved provider.

## Monitor target

Create one HTTPS `GET` monitor for each production tenant:

```text
https://<tenant>.<base-domain>/healthz
```

Require:

- status `200`;
- body `ok`;
- TLS certificate validation;
- a 10-second timeout;
- a 60-second interval;
- no redirects.

If the public frontend has a separate health endpoint, create a second monitor
for that endpoint using the same TLS and timeout requirements. Do not point an
external monitor at the dashboard, Grafana, Prometheus, Loki, Alloy, `/metrics`,
Docker API, or any private network address.

## Provider setup

Start with the checked-in provider-neutral example:

```text
dashboard/observability/uptime/monitor.example.json
```

Translate its fields into the selected provider's UI or API. Keep the
provider token in the provider's secret store or an operator environment:

```sh
export UPTIME_API_TOKEN='provided-out-of-band'
export UPTIME_MONITOR_ID='provided-by-provider'
```

Never add those values to `.env.example`, a shell history committed to the
repository, or a Grafana annotation.

Configure two notification paths in the provider when available:

1. primary operator Slack/email destination;
2. secondary escalation destination owned by a different operator.

The external monitor is intentionally independent of the self-hosted
observability stack so it can still report a host, Docker, or Grafana outage.

## Test and handoff

1. Verify a normal `200`/`ok` check.
2. In a maintenance window, stop only the public health target or block it
   through the approved maintenance mechanism.
3. Confirm the provider opens and resolves an incident.
4. Record monitor ID, target URL, interval, timeout, escalation policy, and
   last successful check in the operations inventory.
5. Remove any temporary test suppression.

If no provider or credential is available, leave the example unchanged and
record the missing account/token as an operational blocker rather than
creating a public endpoint or embedding a secret.
