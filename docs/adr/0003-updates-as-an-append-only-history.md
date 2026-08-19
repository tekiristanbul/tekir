# 0003. updates as an append-only history with keyset pagination

- status: accepted
- date: 2026-08-19
- source: issue #3, issue #80, issue #101; `docs/architecture/db.md` (`updates`,
  design notes), `docs/architecture/api.md` (updates, modeling notes)
- supersedes: —

## context

a street cat is cared for by several unrelated people who do not coordinate.
[`docs/product/updates.md`](../product/updates.md) treats their observations as a
shared history rather than as edits to a single record, and
[`docs/product/trust.md`](../product/trust.md) accepts that two people may report
things that disagree.

that rules out a mutable "current state" row per cat: whoever wrote last would
overwrite everyone else, and the disagreement — which is information — would
disappear.

## decision

`updates` is the history spine. every observation is a new row; nothing is
overwritten.

- an update carries one or more structured statuses from a fixed vocabulary
  (`seen`, `fed`, `water_provided`, approved on issue #3) in `update_statuses`,
  plus an optional free-text comment and optional media.
- needing help is a flag on the same row, not a separate resource:
  `needs_help` boolean plus `needs_help_category` and a persisted
  `needs_help_expires_at` (issue #101 replaced the earlier `kind` subtype, which
  no longer drives any read path). expiry is stored per row so changing the
  window later cannot silently reinterpret an alert that already exists.
- corrections are bounded, not free editing: a 10-minute window sets
  `updated_at` (issue #80). deletion is a `deleted_at` tombstone, never a row
  removal, and every read path filters it in sql.
- a cat's active alert is *derived* from its latest non-deleted, non-expired
  help-carrying update. the api never stores or returns an authoritative single
  status for a cat.
- history is paginated by keyset on `(created_at desc, seq desc)`, where `seq`
  is a `bigserial` monotonic tie-breaker.

## alternatives considered

- **a single mutable status per cat.** rejected by
  [`docs/product/trust.md`](../product/trust.md) and restated in
  `docs/architecture/api.md`'s modeling notes: conflicting updates stay visible
  as ordered history and the api deliberately does not resolve them.
- **ordering history by `created_at` alone.** rejected in
  `docs/architecture/db.md`: two updates can share a timestamp under fast writes
  or seeding, so `created_at` alone does not order them deterministically and a
  keyset cursor built on it would skip or repeat rows.

## consequences

- the table only grows. a busy cat's history is unbounded, and there is no
  archival or compaction path today.
- every read of a cat has to derive its alert state at query time against an
  injected clock, and the filtering query and the response derivation must agree
  on the same instant — `ListDiscover` captures `now` once and reuses it for
  exactly this reason.
- soft deletion means every current and future query touching `updates` must
  remember `deleted_at is null`. a missed predicate resurrects deleted content,
  which is why the filter lives in sql rather than in the service layer.
- `seq` is a database-assigned sequence, so cursors are not portable across a
  dump/restore that renumbers it.
