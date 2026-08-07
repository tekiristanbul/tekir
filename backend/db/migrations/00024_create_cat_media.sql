-- +goose Up
-- issue #121 (product-owner approved architecture decision on the issue):
-- images-only multi-media support for the cat-profile parity gaps this
-- issue's audit recorded (media tab/archive, per-update thumbnail, cover
-- photo counter). video is explicitly out of scope — no upload/transcoding
-- pipeline exists, and none is added here.
--
-- updates.media_id mirrors the column docs/architecture/db.md's `updates`
-- table already sketched (deferred since migration 00004, the same way
-- author_device_id/author_user_id were each deferred until their own write
-- path existed). No write path sets it yet — CreateOrdinaryUpdate still
-- accepts no media from the caller (see its own comment) — this only adds
-- the read-side plumbing docs/design/screens/cat-profile.html's per-update
-- thumbnail needs once a future upload path populates it.
alter table updates add column media_id uuid references media(id);

-- cat_media is the photo archive backing the design's "medya" tab and the
-- cover's photo-count pill. A join table, not a single column on cats, since
-- a cat may end up with more than one photo once a future write path adds
-- them; unique (cat_id, media_id) keeps a retried/duplicate insert of the
-- same photo a no-op rather than a second archive entry.
create table cat_media (
  id         uuid primary key default gen_random_uuid(),
  cat_id     uuid not null references cats(id),
  media_id   uuid not null references media(id),
  created_at timestamptz not null default now(),
  unique (cat_id, media_id)
);
create index cat_media_cat_idx on cat_media (cat_id, created_at);

-- backfill: every existing cat's current cover photo becomes its first (and,
-- until a future write path adds more, only) archive entry — the cover
-- counter and media tab must not read as empty for a cat that already has a
-- photo.
insert into cat_media (cat_id, media_id, created_at)
select c.id, c.primary_photo_id, c.created_at
from cats c
where c.primary_photo_id is not null
on conflict (cat_id, media_id) do nothing;

-- +goose Down
drop table cat_media;
alter table updates drop column media_id;
