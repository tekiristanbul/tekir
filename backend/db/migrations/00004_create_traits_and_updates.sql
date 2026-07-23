-- +goose Up
-- minimum schema for issue #21 (cat detail + update history).
--
-- traits: a controlled, extensible vocabulary per the product clarification
-- on issue #21 — not a postgres enum (would need a migration to add/rename/
-- retire a value), not a free-text column (users can't type arbitrary
-- traits), not an array (loses the ability to attach mutable display
-- metadata or a stable identity per trait). `key` is the stable machine
-- identity a client/db can reference forever; `display_name` is mutable
-- metadata that can be re-labeled without touching any cat_traits row.
-- `active` retires a trait from future selection without deleting it, so
-- existing cat_traits associations (and their historical meaning) survive.
create table traits (
  key          text primary key,
  display_name text not null,
  active       boolean not null default true,
  sort_order   int not null,
  created_at   timestamptz not null default now()
);

-- references traits(key), not a free-text column: a cat can only carry a
-- trait that exists in the vocabulary. no cascade on retiring a trait
-- (active=false) — the row simply stops appearing in ListActiveTraits.
create table cat_traits (
  cat_id     uuid not null references cats(id),
  trait_key  text not null references traits(key),
  primary key (cat_id, trait_key)
);
create index cat_traits_trait_idx on cat_traits (trait_key);

-- seq gives pagination a deterministic, monotonic tie-breaker for rows that
-- share created_at (timestamptz precision can collide under fast seeding/
-- tests); created_at alone is not enough to order those deterministically.
-- media_id/author_device_id from docs/architecture/db.md are deferred like
-- cats.created_by_device_id/primary_photo_id (see 00003): there's no
-- media/devices table yet, and issue #21 is read-only (no update creation).
create table updates (
  id          uuid primary key default gen_random_uuid(),
  cat_id      uuid not null references cats(id),
  comment     text,
  created_at  timestamptz not null default now(),
  seq         bigserial
);
create index updates_cat_created_idx on updates (cat_id, created_at desc, seq desc);

-- one row per structured status on an update (an update may carry several,
-- e.g. "seen" + "water_provided"). fixed check constraint, not free text:
-- issue #3 approved this exact vocabulary for the mvp, unlike cat traits.
create table update_statuses (
  update_id  uuid not null references updates(id),
  status     text not null check (status in ('seen', 'fed', 'water_provided')),
  primary key (update_id, status)
);

-- +goose Down
drop table update_statuses;
drop table updates;
drop table cat_traits;
drop table traits;
