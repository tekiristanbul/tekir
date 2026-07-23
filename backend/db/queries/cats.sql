-- name: UpsertCat :one
insert into cats (id, name, area, photo_url, status, last_update_at, needs_help_until)
values (
  sqlc.arg(id),
  sqlc.arg(name),
  st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326)::geography,
  sqlc.arg(photo_url),
  sqlc.arg(status),
  sqlc.arg(last_update_at),
  sqlc.arg(needs_help_until)
)
on conflict (id) do update set
  name = excluded.name,
  area = excluded.area,
  photo_url = excluded.photo_url,
  status = excluded.status,
  last_update_at = excluded.last_update_at,
  needs_help_until = excluded.needs_help_until
returning id;

-- name: ListCatsInBounds :many
-- area && envelope::geography uses cats_area_gix (gist on geography supports
-- the && bounding-box operator); st_makeenvelope builds the requested viewport.
select
  id,
  photo_url,
  st_x(area::geometry)::float8 as lng,
  st_y(area::geometry)::float8 as lat,
  (needs_help_until is not null and needs_help_until > now()) as needs_help,
  last_update_at
from cats
where status = 'active'
  and area && st_setsrid(
    st_makeenvelope(sqlc.arg(min_lng)::float8, sqlc.arg(min_lat)::float8, sqlc.arg(max_lng)::float8, sqlc.arg(max_lat)::float8),
    4326
  )::geography
order by created_at desc;
