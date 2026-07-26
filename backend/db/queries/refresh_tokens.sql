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
-- idempotent, unconditional revoke — used only by logout, where "already
-- revoked/expired" is not an error (see SessionService.Revoke). Never used
-- for rotation; see RevokeRefreshTokenIfActive for that.
update refresh_tokens set revoked_at = sqlc.arg(revoked_at) where id = sqlc.arg(id);

-- name: RevokeRefreshTokenIfActive :one
-- atomic conditional revoke (code review fix, issue #58): the previous
-- read-then-unconditional-revoke let two concurrent refresh calls
-- presenting the same token both pass validation before either revoked
-- it, so both could mint a replacement session from one token. this
-- statement re-evaluates "unrevoked and unexpired" atomically against the
-- row's current committed state; a concurrent loser's update commits
-- after the winner's and matches zero rows, since revoked_at is no longer
-- null by then.
update refresh_tokens
set revoked_at = sqlc.arg(revoked_at)
where id = sqlc.arg(id)
  and revoked_at is null
  and expires_at > sqlc.arg(now)
returning user_id;
