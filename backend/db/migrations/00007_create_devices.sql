-- +goose Up
-- issue #32: anonymous device identity — implements the devices table so
-- POST /v1/devices can issue a server-generated credential without ever
-- storing the raw token. user_id is intentionally absent: the users table
-- does not exist yet; a later migration adds that column as a foreign key
-- once users lands (see docs/architecture/db.md). platform includes 'web'
-- because the flutter application has a web target (see
-- docs/architecture/flutter.md).
create table devices (
  id          uuid primary key default gen_random_uuid(),
  token_hash  text unique not null,
  push_token  text,
  platform    text not null check (platform in ('ios', 'android', 'web')),
  revoked_at  timestamptz,
  created_at  timestamptz not null default now()
);

-- +goose Down
drop table devices;
