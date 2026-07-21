# db

## goal

define the mvp schema backing [[api]], on postgres + postgis.

## decisions

```sql
create extension if not exists postgis;

create table devices (
  id               uuid primary key,
  push_token       text,
  platform         text check (platform in ('ios','android')),
  user_id          uuid references users(id),
  created_at       timestamptz not null default now()
);

create table users (
  id                 uuid primary key default gen_random_uuid(),
  phone              text unique not null,
  phone_verified_at  timestamptz not null,
  created_at         timestamptz not null default now()
);

create table media (
  id                    uuid primary key default gen_random_uuid(),
  url                   text not null,
  uploaded_by_device_id uuid not null references devices(id),
  created_at            timestamptz not null default now()
);

create table cats (
  id                 uuid primary key default gen_random_uuid(),
  name               text,
  area               geography(point, 4326) not null,
  primary_photo_id   uuid references media(id),
  status             text not null default 'active' check (status in ('active','inactive')),
  last_update_at     timestamptz,
  needs_help_until   timestamptz,
  created_by_device_id uuid not null references devices(id),
  created_at         timestamptz not null default now()
);
create index cats_area_gix on cats using gist (area);
create index cats_needs_help_idx on cats (needs_help_until);

create table cat_traits (
  cat_id  uuid not null references cats(id),
  trait   text not null,
  primary key (cat_id, trait)
);

create table updates (
  id                uuid primary key default gen_random_uuid(),
  cat_id            uuid not null references cats(id),
  type              text not null check (type in ('status','help_request')),
  comment           text,
  media_id          uuid references media(id),
  author_device_id  uuid not null references devices(id),
  created_at        timestamptz not null default now()
);
create index updates_cat_created_idx on updates (cat_id, created_at desc);

create table follows (
  device_id  uuid not null references devices(id),
  cat_id     uuid not null references cats(id),
  created_at timestamptz not null default now(),
  primary key (device_id, cat_id)
);
create index follows_cat_idx on follows (cat_id);

create table notifications (
  id         uuid primary key default gen_random_uuid(),
  device_id  uuid not null references devices(id),
  cat_id     uuid not null references cats(id),
  update_id  uuid not null references updates(id),
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index notif_device_created_idx on notifications (device_id, created_at desc);
```

### design notes

- `cats.area` is a point; the ~50m "area" concept from [[cats]] is expressed at query time via `st_dwithin(area, point, 50)` rather than a separate area table — that table would add complexity with no behavior it doesn't already give.
- `cats.needs_help_until`: set to `now() + <duration>` whenever a new `help_request` update lands. the duration is a config value — [[alerts]] never settled on one.
- `cats.last_update_at`: refreshed on every new update, so the map's "recently updated" highlight ([[map]]) needs no join.
- `cat_traits.trait` is free text. no taxonomy is decided; a later move to a fixed list/enum doesn't require restructuring this table.
- `cats.status`: cats are never deleted, only marked `inactive`, per [[cats]]. the threshold for going inactive (silence duration) is undecided — left as a job/cron concern, the schema doesn't need to know the number.
- no duplicate-merge table exists yet. `nearby` lookups are computed on the fly; once a merge mechanism is decided ([[cats]]), a `cats.merged_into` column is the likely addition.
- `devices.user_id`: set once phone verification succeeds. because follows/updates are already keyed by `device_id`, linking it to a `user_id` doesn't require a data migration — history is already attached.

## open questions

- `needs_help` expiry duration.
- cat-inactivity threshold.
- trait taxonomy (or confirmation that free text is the permanent shape).
- duplicate-cat merge mechanism and whether it needs a `merged_into` column or something richer.

## out of scope

- read replicas / sharding — not warranted at mvp scale.
- audit logging / soft-delete history beyond `cats.status`.
