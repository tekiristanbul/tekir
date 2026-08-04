-- name: CreateNotificationOutbox :exec
-- issue #38: explicit enqueue replaces the removed updates_enqueue_outbox
-- trigger (migration 00009) — Store.CreateOrdinaryUpdate is now the only
-- caller, inside the same transaction as the update/statuses/last_update_at
-- writes, so only an authenticated ordinary write ever produces outbox
-- work. notification_outbox.update_id is unique, so retrying or repeating
-- an enqueue for the same update fails loudly (and rolls the whole
-- transaction back) instead of duplicating work.
--
-- needs_help_eligible (issue #105): notification eligibility is decided
-- here, atomically with the update insert, and frozen into the outbox row
-- — never re-derived at dispatch time. A help mark is eligible exactly
-- when the cat had no other active help state at the mark's creation
-- (inactive → active transition); a mark made while an earlier unexpired,
-- undeleted mark existed is ineligible forever, even if that earlier mark
-- is later corrected away or deleted before the worker runs (the issue
-- #105 race). Evaluated inside the creating transaction, so it sees
-- exactly the state the mark was made against.
insert into notification_outbox (update_id, cat_id, needs_help_eligible)
select u.id, u.cat_id,
  case when u.needs_help then not exists (
    select 1 from updates p
    where p.cat_id = u.cat_id
      and p.needs_help
      and p.deleted_at is null
      and p.id <> u.id
      and (p.created_at < u.created_at or (p.created_at = u.created_at and p.seq < u.seq))
      and p.needs_help_expires_at > u.created_at
  ) else false end
from updates u
where u.id = sqlc.arg(update_id);

-- name: ClaimNotificationOutboxBatch :many
-- issue #78: the notification worker's read step. `for update skip locked`
-- lets more than one worker process poll concurrently without claiming the
-- same row twice — a second worker just skips a row the first already
-- locked, rather than blocking on it or double-processing it once the
-- first commits. joins updates for `needs_help`/`author_user_id` since the
-- outbox itself doesn't carry them: an ordinary-update row's outbox entry
-- is real (Store.CreateOrdinaryUpdate enqueues one for every write) but
-- must never fan out to followers (see docs/product/notifications.md — mvp
-- only notifies for needs-help), so the caller marks it processed with no
-- recipients rather than skipping it here.
--
-- needs_help_eligible (issue #105, superseding #101's claim-time
-- computation): whether a help mark notifies followers was decided once,
-- inside the transaction that created it (see CreateNotificationOutbox
-- above), and is read back verbatim here — this query never re-derives it
-- from the mutable updates rows, so an earlier active mark being deleted
-- or corrected away between the newer mark's creation and this dispatch
-- can no longer flip the verdict. The re-marking product decision (#101,
-- on the #100 contract) is unchanged: an already-active cat's newer mark
-- saves and restarts the 72h window but is never eligible to notify.
-- needs_help still reads the mark's own live row (flag and deleted_at):
-- an author retracting their mark in-window before dispatch cancels the
-- send — that is the mark itself, not the cat's aggregate help state.
select o.id, o.update_id, o.cat_id,
  (u.needs_help and u.deleted_at is null)::bool as needs_help,
  u.author_user_id,
  o.needs_help_eligible
from notification_outbox o
join updates u on u.id = o.update_id
where o.processed_at is null
order by o.created_at
limit sqlc.arg(row_limit)::int
for update of o skip locked;

-- name: MarkNotificationOutboxProcessed :exec
-- issue #78: called once per claimed row, after recipient resolution and
-- (best-effort) delivery — including when delivery itself failed, since a
-- send failure must never re-surface as a needs-help update rollback or an
-- outbox row stuck retrying forever (see docs/product/notifications.md's
-- at-most-once delivery acceptance for mvp).
update notification_outbox set processed_at = sqlc.arg(processed_at)
where id = sqlc.arg(id);
