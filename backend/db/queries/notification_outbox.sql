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
