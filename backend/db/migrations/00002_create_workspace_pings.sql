-- +goose Up
-- smoke-test table only, to prove migrations/seed/postgis work end to end.
-- not part of the product schema; drop once real tables (docs/architecture/db.md) land.
create table workspace_pings (
  id         uuid primary key default gen_random_uuid(),
  message    text not null,
  location   geography(point, 4326),
  created_at timestamptz not null default now()
);

-- +goose Down
drop table workspace_pings;
