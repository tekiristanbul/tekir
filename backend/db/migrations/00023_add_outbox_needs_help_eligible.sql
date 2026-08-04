-- +goose Up
-- issue #105: notification eligibility for a help mark is decided once,
-- atomically inside the transaction that creates the update (see
-- CreateNotificationOutbox in db/queries/notification_outbox.sql), and
-- frozen here — the worker's claim query previously re-computed the
-- "already active" suppression against the mutable updates rows at
-- dispatch time, so deleting/correcting an earlier active mark between a
-- newer mark's creation and its dispatch could incorrectly turn the newer
-- mark's suppressed enqueue into a push.
alter table notification_outbox add column needs_help_eligible boolean not null default false;

-- backfill unprocessed rows with the verdict the enqueue would have
-- frozen at creation, evaluated the same way the removed claim-time
-- expression did (against the mark's own created_at). Processed rows are
-- never read for eligibility again and keep the default. The unavoidable
-- imprecision — an earlier mark deleted before this migration runs no
-- longer suppresses — matches exactly what the old claim query would have
-- computed for these same rows, so no in-flight row changes verdict by
-- migrating.
update notification_outbox o
set needs_help_eligible = (
  select u.needs_help and not exists (
    select 1 from updates p
    where p.cat_id = u.cat_id
      and p.needs_help
      and p.deleted_at is null
      and p.id <> u.id
      and (p.created_at < u.created_at or (p.created_at = u.created_at and p.seq < u.seq))
      and p.needs_help_expires_at > u.created_at
  )
  from updates u where u.id = o.update_id
)
where o.processed_at is null;

-- +goose Down
alter table notification_outbox drop column needs_help_eligible;
