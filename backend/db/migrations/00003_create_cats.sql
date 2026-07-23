-- +goose Up
-- minimal cats table, scoped to what the map marker query (issue #7) needs.
-- created_by_device_id/primary_photo_id -> media(id) from docs/architecture/db.md
-- are deferred until the auth/add-cat issues stand up devices/media/users;
-- photo_url is a plain column until then.
create table cats (
  id                uuid primary key default gen_random_uuid(),
  name              text,
  area              geography(point, 4326) not null,
  photo_url         text,
  status            text not null default 'active' check (status in ('active', 'inactive')),
  last_update_at    timestamptz,
  needs_help_until  timestamptz,
  created_at        timestamptz not null default now()
);
create index cats_area_gix on cats using gist (area);
create index cats_needs_help_idx on cats (needs_help_until);

-- +goose Down
drop table cats;
