---
applyTo: "backend/db/migrations/**/*.sql,backend/db/seed/**/*.sql,backend/cmd/seed/**/*.go"
---

# migrations and seed data

- migrations are forward-only and immutable: never edit an existing migration; add the next migration.
- use constraints to prevent invalid states and avoid postgres enums.
- verify migration up from an empty database and upgrade from the current schema with representative existing data.
- keep seed execution idempotent and deterministic.
- add rollback logic only when the repository's migration system supports it and the change can be reversed safely.
- fail explicitly rather than silently discarding or rewriting ambiguous existing data.
