-- name: UpsertCat :one
insert into cats (id, name, area, area_label, photo_url, status, last_update_at)
values (
  sqlc.arg(id),
  sqlc.arg(name),
  st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326)::geography,
  sqlc.arg(area_label),
  sqlc.arg(photo_url),
  sqlc.arg(status),
  sqlc.arg(last_update_at)
)
on conflict (id) do update set
  name = excluded.name,
  area = excluded.area,
  area_label = excluded.area_label,
  photo_url = excluded.photo_url,
  status = excluded.status,
  last_update_at = excluded.last_update_at
returning id;

-- name: ListCatsInBounds :many
-- area && envelope::geography uses cats_area_gix (gist on geography supports
-- the && bounding-box operator); st_makeenvelope builds the requested viewport.
-- name/area_label are the minimum extra fields the map-marker preview sheet
-- needs (issue #21 prototype-parity correction) — no second full-detail
-- fetch on marker tap. the lateral join returns each cat's latest
-- needs-help update (issue #4/#23), whether or not it has since expired —
-- ListNearby (service layer) is the one that decides active-vs-expired,
-- against an injected clock, not this query's own now().
select
  c.id,
  c.name,
  c.photo_url,
  st_x(c.area::geometry)::float8 as lng,
  st_y(c.area::geometry)::float8 as lat,
  c.area_label,
  c.last_update_at,
  nh.needs_help_category,
  nh.created_at as needs_help_created_at,
  nh.needs_help_expires_at
from cats c
left join lateral (
  select u.needs_help_category, u.created_at, u.needs_help_expires_at
  from updates u
  where u.cat_id = c.id and u.kind = 'needs_help'
  order by u.created_at desc, u.seq desc
  limit 1
) nh on true
where c.status = 'active'
  and c.area && st_setsrid(
    st_makeenvelope(sqlc.arg(min_lng)::float8, sqlc.arg(min_lat)::float8, sqlc.arg(max_lng)::float8, sqlc.arg(max_lat)::float8),
    4326
  )::geography
order by c.created_at desc;

-- name: GetCatByID :one
-- traits are fetched separately via ListCatTraits (join against the traits
-- vocabulary) rather than aggregated in here, so each trait can carry its
-- display_name without hand-rolling composite-type aggregation in sql. the
-- lateral join is the same latest-needs-help-update lookup as
-- ListCatsInBounds, unfiltered by expiry for the same reason.
select
  c.id,
  c.name,
  st_x(c.area::geometry)::float8 as lng,
  st_y(c.area::geometry)::float8 as lat,
  c.area_label,
  c.photo_url,
  c.created_at,
  c.last_update_at,
  nh.needs_help_category,
  nh.created_at as needs_help_created_at,
  nh.needs_help_expires_at
from cats c
left join lateral (
  select u.needs_help_category, u.created_at, u.needs_help_expires_at
  from updates u
  where u.cat_id = c.id and u.kind = 'needs_help'
  order by u.created_at desc, u.seq desc
  limit 1
) nh on true
where c.id = sqlc.arg(id);

-- name: CatExists :one
-- lets the updates-history endpoint 404 on an unknown cat instead of
-- silently returning an empty page indistinguishable from "no history yet".
select exists(select 1 from cats where id = sqlc.arg(id)) as exists;
