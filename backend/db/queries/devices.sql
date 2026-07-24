-- name: CreateDevice :one
-- stores a new device row; only the sha-256 hash of the raw token is
-- persisted here — the raw token is returned to the caller once and
-- never stored (see docs/architecture/db.md). push_token is optional.
insert into devices (id, token_hash, push_token, platform)
values (sqlc.arg(id), sqlc.arg(token_hash), sqlc.narg(push_token), sqlc.arg(platform))
returning id, created_at;

-- name: GetDeviceByTokenHash :one
-- resolves an inbound X-Device-Token to its non-secret device_id.
-- the middleware calls this after hashing the presented token; only
-- the non-secret fields are returned — the hash is never echoed back.
select id, revoked_at
from devices
where token_hash = sqlc.arg(token_hash);
