# Data Model: Goose MySQL Authentication Parity

No database schema or persisted application data changes are required.

## Existing operational entities

| Entity | Relevant attributes | Validation/relationship |
|---|---|---|
| Database connection configuration | Host, port, database name, user, password | Both readiness and migration paths resolve these from the existing deployment configuration. |
| Migration readiness result | Success or categorized connection/authentication failure | A failure stops the migration before backup or schema changes. |
| Master migration ledger | Existing migration version records | Its schema and lifecycle are unchanged by this feature. |

The configured password is secret data. It is not persisted in feature
artifacts, test output, or operator diagnostics.
