-- name: CreateFollow :exec
-- idempotent by construction: on conflict do nothing means a repeat follow
-- for the same (device_id, cat_id) pair — including two concurrent
-- duplicate requests — leaves exactly one row, never an error or a
-- duplicate (issue #44).
insert into follows (device_id, cat_id)
values (sqlc.arg(device_id), sqlc.arg(cat_id))
on conflict (device_id, cat_id) do nothing;

-- name: DeleteFollow :exec
-- idempotent: unfollowing a cat this device doesn't currently follow
-- deletes zero rows and succeeds silently rather than erroring (issue #44).
delete from follows where device_id = sqlc.arg(device_id) and cat_id = sqlc.arg(cat_id);

-- name: ListFollowedCats :many
-- issue #44: a device's followed cats, ordered by most recent cat activity.
-- last_update_at desc nulls last puts a cat that has never had an update
-- after every cat that has, however old — no activity is never "fresher"
-- than old activity. c.id desc is the deterministic tie-breaker for equal
-- last_update_at, including the shared-null case, since last_update_at
-- alone can't order two never-updated cats against each other. joins cats
-- (not just follows) so the response carries the same cat-summary shape as
-- the map/detail endpoints, including each cat's latest needs-help update
-- via the same unfiltered-by-expiry lateral join as ListCatsInBounds/
-- GetCatByID — the service layer decides active-vs-expired against its own
-- injected clock, never this query's own now().
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
from follows f
join cats c on c.id = f.cat_id
left join lateral (
  select u.needs_help_category, u.created_at, u.needs_help_expires_at
  from updates u
  where u.cat_id = c.id and u.kind = 'needs_help'
  order by u.created_at desc, u.seq desc
  limit 1
) nh on true
where f.device_id = sqlc.arg(device_id)
order by c.last_update_at desc nulls last, c.id desc;
