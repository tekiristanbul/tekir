-- +goose Up
-- issue #58: backs the access_token/refresh_token pair issued by otp
-- verification and rotated by POST /v1/auth/refresh. only the sha-256 hash
-- of the raw refresh token is stored, matching devices.token_hash's
-- convention — the raw token exists only in the response body and the
-- client's secure storage. refresh rotation revokes the presented row and
-- inserts a new one rather than reusing it, so a stolen-and-replayed
-- refresh token stops working the moment the legitimate client rotates it.
create table refresh_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users(id),
  token_hash text unique not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index refresh_tokens_user_idx on refresh_tokens (user_id);

-- +goose Down
drop table refresh_tokens;
