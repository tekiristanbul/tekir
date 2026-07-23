-- +goose Up
-- issue #23: trait groups + needs-help as an explicit update subtype.
-- purely additive against 00001-00005 — none of those files are touched.

-- trait groups: metadata for the future grouped multi-select picker
-- (product-owner decision on issue #21/#23) — a section header per group,
-- not a schema change per group added later. nullable traits.group_key
-- below: assigning a group is a data concern (seed/future admin flow), not
-- a schema-level requirement, so no backfill is needed for a trait row that
-- predates grouping.
create table trait_groups (
  key          text primary key,
  display_name text not null,
  sort_order   int not null
);

alter table traits add column group_key text references trait_groups(key);

-- needs-help (issue #4 final decision: 5 fixed categories, 72h expiry, no
-- resolve action) is an explicit update subtype sharing the same `updates`
-- history table as an ordinary status update, not a separate table —
-- mirrors how update_statuses already models ordinary updates as a fixed,
-- closed vocabulary rather than free text. `kind` discriminates the two;
-- the check constraint below makes an invalid ordinary/needs-help field
-- combination unrepresentable at the database level.
alter table updates add column kind text not null default 'ordinary' check (kind in ('ordinary', 'needs_help'));

alter table updates add column needs_help_category text check (
  needs_help_category in ('injured_or_sick', 'food_needed', 'water_needed', 'unsafe_location', 'trapped')
);

-- server-computed as created_at + 72h at write time (see docs/architecture/
-- api.md) and persisted explicitly rather than derived from created_at on
-- every read — a future change to the expiry window must not silently
-- reinterpret an alert that already expired under the old one. activeness
-- itself is never a separate stored flag: it's always (this) expires_at
-- compared against the current time at read time.
alter table updates add column needs_help_expires_at timestamptz;

alter table updates add constraint updates_kind_fields_ck check (
  (kind = 'ordinary' and needs_help_category is null and needs_help_expires_at is null)
  or
  (kind = 'needs_help' and needs_help_category is not null and needs_help_expires_at is not null)
);

-- supports "the latest needs-help update for cat X" (the map/cat-detail
-- active-alert lookup, see db/queries/cats.sql) without a full table scan.
create index updates_needs_help_idx on updates (cat_id, created_at desc, seq desc) where kind = 'needs_help';

-- cats.needs_help_until (00003) predated this issue and duplicated the same
-- fact updates.needs_help_expires_at now holds authoritatively — two
-- columns for one fact is exactly the "separate mutable state that can
-- drift" shape issue #23 asks to avoid, so it's dropped in favor of a
-- single source of truth (see docs/architecture/db.md).
drop index if exists cats_needs_help_idx;
alter table cats drop column needs_help_until;

-- +goose Down
alter table cats add column needs_help_until timestamptz;
create index cats_needs_help_idx on cats (needs_help_until);

drop index if exists updates_needs_help_idx;
alter table updates drop constraint updates_kind_fields_ck;
alter table updates drop column needs_help_expires_at;
alter table updates drop column needs_help_category;
alter table updates drop column kind;

alter table traits drop column group_key;
drop table trait_groups;
