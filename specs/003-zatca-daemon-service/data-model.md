# Data Model: ZATCA Daemon Deployment

This deployment feature has no application database migration. The following
configuration entities are the external contract consumed by the service.

| Entity | Fields | Validation |
|---|---|---|
| Daemon image | `ZATCA_DAEMON_IMAGE` | Non-empty approved image reference; supplied by operator/release pipeline. |
| Runtime DB account | `ZATCA_DB_USER`, `ZATCA_DB_PASSWORD` | Non-empty; account can read/update required tenant tables and read the master registry. |
| Master DB location | `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_MASTER_DB` | Reuses existing deployment values; master DB name must match the registry created by setup. |
| Optional onboarding account | `ZATCA_ADMIN_DB_USER`, `ZATCA_ADMIN_DB_PASSWORD` | Either both set or both empty; required only when onboarding needs elevated tenant writes. |
| Queue endpoint | `NATS_PORT`, `ZATCA_NATS_URL` | NATS URL points to the daemon-owned host-published client port. |
| Persistent paths | `ZATCA_XML_ROOT`, `ZATCA_NATS_DATA_ROOT` | Host directories are created before Compose startup and bind-mounted to the T008 paths. |
| Protected runtime secrets | `ZATCA_ENCRYPT_KEY`, `ZATCA_MONITOR_PASSWORD` | Non-empty; values are never committed or printed. |

## Relationships

- One daemon owns one embedded JetStream instance.
- One master registry references many enabled tenant databases.
- One daemon runtime account spans the configured master registry and the
  tenant database pattern.
- One daemon XML root contains tenant-scoped signed XML artifacts.
