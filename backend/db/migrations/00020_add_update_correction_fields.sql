-- +goose Up
-- issue #80: the 10-minute update-correction window (docs/product/updates.md)
-- needs somewhere to record an edit and a delete. updated_at is set only by
-- a successful correction (never by CreateUpdate's own seed/idempotent
-- upsert path); deleted_at is a soft-delete tombstone, not a real row
-- removal — a hard delete would violate notification_outbox.update_id and
-- notifications.update_id, which reference updates(id) with no
-- on delete cascade, and would destroy the delivery-audit trail
-- docs/architecture/db.md describes for the at-most-once push guarantee.
-- to every reader other than the author, a soft-deleted update simply
-- disappears from GET /v1/cats/{cat_id}/updates (see updates.sql's
-- ListCatUpdates change below) and can never reappear — the same visible
-- effect updates.md's "remove your own update" implies — while the row
-- itself survives to satisfy the issue's "preserve immutable audit fields"
-- and concurrency-check constraints. Neither column is ever set outside
-- the correction/delete write path introduced alongside this migration
-- (see repository.Store.CorrectOwnUpdate/DeleteOwnUpdate).
alter table updates add column updated_at timestamptz;
alter table updates add column deleted_at timestamptz;

-- backs the correction window's own lookups (badge derivation's oldest-
-- first walk over a user's ordinary, non-deleted updates, and the
-- correction/delete write path's own where-clause) without a sequential
-- scan. Partial: needs-help rows and already-deleted rows are never
-- targeted by either query this serves.
create index updates_author_correction_idx on updates (author_user_id, created_at)
  where kind = 'ordinary' and deleted_at is null;

-- +goose Down
drop index updates_author_correction_idx;
alter table updates drop column deleted_at;
alter table updates drop column updated_at;
