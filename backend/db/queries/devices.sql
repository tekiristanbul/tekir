-- name: CreateDevice :one
-- stores a new device row; only the sha-256 hash of the raw token is
-- persisted here — the raw token is returned to the caller once and
-- never stored (see docs/architecture/db.md). push_token is optional.
insert into devices (id, token_hash, push_token, platform)
values (sqlc.arg(id), sqlc.arg(token_hash), sqlc.narg(push_token), sqlc.arg(platform))
returning id, created_at;

-- name: GetDeviceByTokenHash :one
-- resolves an inbound X-Device-Token to its non-secret device_id and, if
-- the device has been linked to an account (issue #58), that account's id.
-- the middleware calls this after hashing the presented token; only
-- the non-secret fields are returned — the hash is never echoed back.
select id, revoked_at, user_id
from devices
where token_hash = sqlc.arg(token_hash);

-- name: GetDeviceByID :one
-- issue #58: read a device's current account link before deciding whether
-- otp verification may link it (see LinkDeviceToUser).
select id, user_id, revoked_at
from devices
where id = sqlc.arg(id);

-- name: LinkDeviceToUser :exec
-- issue #58: idempotent by construction — setting user_id to the same
-- value on a retry (or on a device already linked to this exact account)
-- is a no-op update. the service layer rejects linking a device already
-- linked to a *different* account before this query ever runs. A device
-- stays linked to at most one account at a time, but issue #80's
-- UnlinkDeviceFromUser (below) can clear that link on logout so the same
-- installation can later link to a different account.
update devices set user_id = sqlc.arg(user_id) where id = sqlc.arg(id);

-- name: UnlinkDeviceFromUser :exec
-- issue #80 (product-owner review): clears a device's account link on
-- logout, so the same installation can sign into a *different* account
-- afterward without linkDevice's "already linked to a different account"
-- check rejecting it forever. The `and user_id = sqlc.arg(user_id)` guard
-- is the entire safety mechanism: this only ever clears a link that
-- currently matches the caller's own account — a mismatched, stale, or
-- already-unlinked device affects zero rows, never another account's
-- link. Never touches follows/updates/any other ownership data; those
-- stay attributed to whichever account actually authored them, forever.
update devices set user_id = null
where id = sqlc.arg(id) and user_id = sqlc.arg(user_id);
