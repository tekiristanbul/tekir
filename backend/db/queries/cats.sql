-- name: UpsertCat :one
insert into cats (id, name, area, area_label, photo_url, status, last_update_at, needs_help_until)
values (
  sqlc.arg(id),
  sqlc.arg(name),
  st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326)::geography,
  sqlc.arg(area_label),
  sqlc.arg(photo_url),
  sqlc.arg(status),
  sqlc.arg(last_update_at),
  sqlc.arg(needs_help_until)
)
on conflict (id) do update set
  name = excluded.name,
  area = excluded.area,
  area_label = excluded.area_label,
  photo_url = excluded.photo_url,
  status = excluded.status,
  last_update_at = excluded.last_update_at,
  needs_help_until = excluded.needs_help_until
returning id;

-- name: ListCatsInBounds :many
-- area && envelope::geography uses cats_area_gix (gist on geography supports
-- the && bounding-box operator); st_makeenvelope builds the requested viewport.
-- name/area_label are the minimum extra fields the map-marker preview sheet
-- needs (issue #21 prototype-parity correction) — no second full-detail
-- fetch on marker tap.
select
  id,
  name,
  photo_url,
  st_x(area::geometry)::float8 as lng,
  st_y(area::geometry)::float8 as lat,
  area_label,
  (needs_help_until is not null and needs_help_until > now()) as needs_help,
  last_update_at
from cats
where status = 'active'
  and area && st_setsrid(
    st_makeenvelope(sqlc.arg(min_lng)::float8, sqlc.arg(min_lat)::float8, sqlc.arg(max_lng)::float8, sqlc.arg(max_lat)::float8),
    4326
  )::geography
order by created_at desc;

-- name: GetCatByID :one
-- traits are fetched separately via ListCatTraits (join against the traits
-- vocabulary) rather than aggregated in here, so each trait can carry its
-- display_name without hand-rolling composite-type aggregation in sql.
select
  c.id,
  c.name,
  st_x(c.area::geometry)::float8 as lng,
  st_y(c.area::geometry)::float8 as lat,
  c.area_label,
  c.photo_url,
  c.created_at,
  c.last_update_at
from cats c
where c.id = sqlc.arg(id);

-- name: CatExists :one
-- lets the updates-history endpoint 404 on an unknown cat instead of
-- silently returning an empty page indistinguishable from "no history yet".
select exists(select 1 from cats where id = sqlc.arg(id)) as exists;
