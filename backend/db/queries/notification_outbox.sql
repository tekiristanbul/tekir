-- name: CreateNotificationOutbox :exec
-- issue #38: explicit enqueue replaces the removed updates_enqueue_outbox
-- trigger (migration 00009) — Store.CreateOrdinaryUpdate is now the only
-- caller, inside the same transaction as the update/statuses/last_update_at
-- writes, so only an authenticated ordinary write ever produces outbox
-- work. notification_outbox.update_id is unique, so retrying or repeating
-- an enqueue for the same update fails loudly (and rolls the whole
-- transaction back) instead of duplicating work.
insert into notification_outbox (update_id, cat_id)
values (sqlc.arg(update_id), sqlc.arg(cat_id));

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
-- needs_help_already_active (issue #101, product-owner decision on the
-- #100 contract's open re-marking question): a help mark made while the
-- cat already had an active help state must not notify followers again —
-- the state silently continues (its 72h window restarts via the newer
-- mark's own expiry). Evaluated against the marked update's own
-- created_at, not dispatch time, so a delayed worker reaches the same
-- verdict a prompt one would; a mark deleted/cleared after this one was
-- created no longer suppresses (bounded, accepted edge — the state it
-- provided was live when this mark was made).
select o.id, o.update_id, o.cat_id,
  (u.needs_help and u.deleted_at is null) as needs_help,
  u.author_user_id,
  ((u.needs_help and u.deleted_at is null) and exists (
    select 1 from updates p
    where p.cat_id = u.cat_id
      and p.needs_help
      and p.deleted_at is null
      and p.id <> u.id
      and (p.created_at < u.created_at or (p.created_at = u.created_at and p.seq < u.seq))
      and p.needs_help_expires_at > u.created_at
  ))::bool as needs_help_already_active
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
