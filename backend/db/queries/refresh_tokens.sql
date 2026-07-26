-- name: CreateRefreshToken :one
-- only the hash is ever persisted; the raw token is returned to the
-- caller once and never stored (mirrors CreateDevice's convention).
insert into refresh_tokens (id, user_id, token_hash, expires_at)
values (sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(token_hash), sqlc.arg(expires_at))
returning id, created_at;

-- name: GetRefreshTokenByHash :one
select id, user_id, token_hash, expires_at, revoked_at, created_at
from refresh_tokens
where token_hash = sqlc.arg(token_hash);

-- name: RevokeRefreshToken :exec
-- idempotent: revoking an already-revoked row just rewrites the same
-- revoked_at-is-set fact, never errors (issue #58 logout/refresh-rotation).
update refresh_tokens set revoked_at = sqlc.arg(revoked_at) where id = sqlc.arg(id);
