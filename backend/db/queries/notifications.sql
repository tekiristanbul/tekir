-- name: CreateNotification :one
-- issue #78: the notification worker's delivery-dedup insert. on conflict
-- (device_id, update_id) do nothing means a retried or concurrently-run
-- dispatch of the same outbox row never creates a second delivery record
-- for the same device — no row comes back (pgx.ErrNoRows) on the
-- conflicting attempt, and the caller (NotificationService.DispatchPending)
-- treats that as "already delivered, don't send again" rather than an
-- error (mirrors db/queries/media.sql's CreateMedia idiom).
insert into notifications (id, device_id, cat_id, update_id)
values (sqlc.arg(id), sqlc.arg(device_id), sqlc.arg(cat_id), sqlc.arg(update_id))
on conflict (device_id, update_id) do nothing
returning *;

-- name: ListMyNotifications :many
-- issue #78: newest-first keyset pagination for GET /v1/me/notifications,
-- mirroring db/queries/updates.sql's ListCatUpdates shape. device_id is
-- resolved from the caller's linked devices (join, not a bare where), so
-- an account only ever sees notifications delivered to a device it
-- currently owns — never another account's, even a former owner of the
-- same device (LinkDeviceToUser only ever adds an owner, see
-- docs/architecture/db.md, so this can't leak a stale link either).
select
  n.id,
  n.cat_id,
  n.update_id,
  n.read_at,
  n.created_at
from notifications n
join devices d on d.id = n.device_id
where d.user_id = sqlc.arg(user_id)
  and (
    sqlc.narg(before_created_at)::timestamptz is null
    or n.created_at < sqlc.narg(before_created_at)::timestamptz
    or (n.created_at = sqlc.narg(before_created_at)::timestamptz and n.id < sqlc.narg(before_id)::uuid)
  )
order by n.created_at desc, n.id desc
limit sqlc.arg(row_limit)::int;

-- name: MarkNotificationRead :exec
-- issue #78: owner-scoped through the same devices.user_id join
-- ListMyNotifications uses, so marking a notification read can never
-- affect a row belonging to another account's device. idempotent —
-- marking an already-read notification read again just re-sets the same
-- timestamp semantics (still "read"), never errors.
update notifications n
set read_at = sqlc.arg(read_at)
from devices d
where n.device_id = d.id
  and n.id = sqlc.arg(id)
  and d.user_id = sqlc.arg(user_id);
