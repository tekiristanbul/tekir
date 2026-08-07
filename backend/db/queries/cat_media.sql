-- name: CreateCatMedia :one
-- issue #121: links a media row into a cat's photo archive. On conflict do
-- nothing on the (cat_id, media_id) unique index so a retried insert of the
-- same photo (e.g. CreateCatWithMedia's own transaction, called again after
-- an idempotent-retry resolves to the same cat and media) never creates a
-- second archive entry — the caller falls back to GetCatMediaByCatAndMedia
-- when no row comes back, mirroring CreateMedia/CreateCat's own idempotent
-- pattern.
insert into cat_media (cat_id, media_id, created_at)
values (sqlc.arg(cat_id), sqlc.arg(media_id), sqlc.arg(created_at))
on conflict (cat_id, media_id) do nothing
returning *;

-- name: GetCatMediaByCatAndMedia :one
select * from cat_media where cat_id = sqlc.arg(cat_id) and media_id = sqlc.arg(media_id);

-- name: CountCatMedia :one
-- backs the cover photo's count pill (docs/design/screens/cat-profile.html)
-- without fetching the full archive.
select count(*) from cat_media where cat_id = sqlc.arg(cat_id);

-- name: ListCatMedia :many
-- backs the "medya" archive tab: newest-first, each row carrying the media
-- it points to plus whether it's the cat's current cover (cats.primary_photo_id)
-- so the client can render the design's "ana" badge without a second lookup.
select
  cm.id,
  cm.cat_id,
  cm.media_id,
  cm.created_at,
  m.url,
  m.content_type,
  (c.primary_photo_id = cm.media_id) as is_cover
from cat_media cm
join media m on m.id = cm.media_id
join cats c on c.id = cm.cat_id
where cm.cat_id = sqlc.arg(cat_id)
order by cm.created_at desc, cm.id desc;
