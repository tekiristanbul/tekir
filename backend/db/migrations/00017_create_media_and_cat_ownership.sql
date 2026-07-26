-- +goose Up
-- issue #70: cat creation and media flow. brings `cats` up to the shape
-- docs/architecture/db.md already sketched (created_by_*/primary_photo_id
-- were deferred by 00003 until add-cat existed) and creates `media` for the
-- first time — there is no pre-#70 media data to migrate. account ownership
-- columns are added from the start (not a later add-column migration),
-- mirroring how 00016 added user_id alongside device_id for follows/updates.
-- idempotency_key on both tables backs "retries must not create duplicate
-- cats/media" (POST /v1/cats and POST /v1/media accept an Idempotency-Key
-- header) with the same partial-unique-index + on-conflict-do-nothing shape
-- 00016 already established for follows_user_cat_uq.
create table media (
  id                    uuid primary key default gen_random_uuid(),
  object_key            text not null,
  url                   text not null,
  content_type          text not null,
  byte_size             int not null,
  uploaded_by_user_id   uuid not null references users(id),
  uploaded_by_device_id uuid references devices(id),
  idempotency_key       text,
  created_at            timestamptz not null default now()
);
create unique index media_user_idempotency_uq on media (uploaded_by_user_id, idempotency_key) where idempotency_key is not null;

alter table cats add column created_by_user_id uuid references users(id);
alter table cats add column created_by_device_id uuid references devices(id);
alter table cats add column primary_photo_id uuid references media(id);
alter table cats add column idempotency_key text;
create unique index cats_user_idempotency_uq on cats (created_by_user_id, idempotency_key) where idempotency_key is not null;

-- +goose Down
drop index cats_user_idempotency_uq;
alter table cats drop column idempotency_key;
alter table cats drop column primary_photo_id;
alter table cats drop column created_by_device_id;
alter table cats drop column created_by_user_id;

drop table media;
