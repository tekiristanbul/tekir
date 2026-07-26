-- +goose Up
-- issue #65: follow and ordinary-update ownership moves from device-only to
-- authenticated-account (bearer), while every pre-existing device-owned row
-- must keep working unchanged. device_id/author_device_id are kept (not
-- dropped) for installation/abuse-control continuity; they simply stop
-- being sufficient for authorization on new writes. see design notes in
-- docs/architecture/db.md.

alter table follows drop constraint follows_pkey;
alter table follows alter column device_id drop not null;
alter table follows add column user_id uuid references users(id);
alter table follows add constraint follows_owner_ck
  check (device_id is not null or user_id is not null);
create unique index follows_device_cat_uq on follows (device_id, cat_id) where device_id is not null;
create unique index follows_user_cat_uq on follows (user_id, cat_id) where user_id is not null;

alter table updates add column author_user_id uuid references users(id);
create index updates_author_user_idx on updates (author_user_id);

-- one-time backfill for any device already linked to an account before this
-- migration ships: idempotent (only touches rows still missing the new
-- column), safe to rerun. AuthService.linkDevice performs the equivalent
-- backfill going forward for links that happen after this ships.
update follows f
set user_id = d.user_id
from devices d
where f.device_id = d.id
  and d.user_id is not null
  and f.user_id is null;

update updates u
set author_user_id = d.user_id
from devices d
where u.author_device_id = d.id
  and d.user_id is not null
  and u.author_user_id is null;

-- +goose Down
-- rolling back drops any row that only exists in the new shape (user_id-only
-- follows have no device_id to satisfy the restored not-null/PK) — this is
-- an intentional, documented loss of new-shape-only data on a schema
-- rollback, not a silent one.
delete from follows where device_id is null;

drop index follows_user_cat_uq;
drop index follows_device_cat_uq;
alter table follows drop constraint follows_owner_ck;
alter table follows add constraint follows_pkey primary key (device_id, cat_id);
alter table follows drop column user_id;
alter table follows alter column device_id set not null;

drop index updates_author_user_idx;
alter table updates drop column author_user_id;
