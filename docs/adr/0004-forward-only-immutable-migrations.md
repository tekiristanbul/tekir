# 0004. forward-only immutable migrations

- status: accepted
- date: 2026-08-19
- source: `.github/instructions/migrations.instructions.md`,
  `backend/db/migrations/`, `backend/Makefile`
- supersedes: —

## context

tekir runs one production database with real user content and no ci deployment
pipeline (see [adr-0005](0005-single-droplet-deployment-without-cd.md)):
migrations are applied by hand from a maintainer machine, ahead of the api
version that needs them. deployed service versions routinely differ from `main`.

under those conditions a schema change that is not strictly additive, or a
migration whose content changed after it was applied somewhere, is not
recoverable by re-running anything.

## decision

migrations are forward-only and immutable.

- an existing migration file is never edited. a correction is the next numbered
  migration. the 28 files in `backend/db/migrations/` are append-only history —
  `00018_repair_follows_user_cat_conflicts.sql` and
  `00022_add_updates_needs_help_flag.sql` are both repairs written as new
  migrations rather than edits to the ones they fix.
- goose is the migration runner, invoked through `make migrate-up` /
  `migrate-status`.
- invalid states are prevented with check constraints rather than postgres
  enums, so a vocabulary can be widened by a later migration without an enum
  type rewrite.
- every change is verified twice: up from an empty database, and upgrade from
  the current schema with representative existing data.
- down migrations are written only when the change is genuinely reversible.
- ambiguous existing data makes a migration fail explicitly; it is never
  silently discarded or rewritten.

## alternatives considered

the source instruction states these rules without recording rejected
alternatives, so none are claimed here.

## consequences

- a mistake ships as a second migration, so schema history is longer and noisier
  than the schema itself.
- rollback is not a database operation. reverting an api version does not revert
  its migration, which is why every schema change has to be backward-compatible
  with the api version already running.
- ci gets real coverage of the up-from-empty path (the backend job runs
  `goose ... up` against a postgis service container), but the
  upgrade-with-existing-data path is verified by hand and is not gated.
