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
-- against an injected clock, not this query's own now(). issue #70: a cat
-- created through POST /v1/cats has primary_photo_id (media table) instead
-- of photo_url (seed-only column, issue #7) — coalesce so both read paths
-- resolve to the same primary_photo field.
select
  c.id,
  c.name,
  coalesce(c.photo_url, m.url, '') as photo_url,
  st_x(c.area::geometry)::float8 as lng,
  st_y(c.area::geometry)::float8 as lat,
  c.area_label,
  c.last_update_at,
  nh.needs_help_category,
  nh.comment as needs_help_comment,
  nh.created_at as needs_help_created_at,
  nh.needs_help_expires_at
from cats c
left join media m on m.id = c.primary_photo_id
left join lateral (
  select u.needs_help_category, u.comment, u.created_at, u.needs_help_expires_at
  from updates u
  where u.cat_id = c.id and u.needs_help and u.deleted_at is null
  order by u.created_at desc, u.seq desc
  limit 1
) nh on true
where c.status = 'active'
  and c.area && st_setsrid(
    st_makeenvelope(sqlc.arg(min_lng)::float8, sqlc.arg(min_lat)::float8, sqlc.arg(max_lng)::float8, sqlc.arg(max_lat)::float8),
    4326
  )::geography
  -- issue #234: hide every cat owned by an account this viewer blocks. a
  -- null viewer (guest, or any unauthenticated read) matches no row here,
  -- so the predicate is a no-op and guest results stay exactly what they
  -- were before blocking existed.
  and not exists (
    select 1 from user_blocks b
    where b.blocker_user_id = sqlc.narg(viewer_user_id)::uuid
      and b.blocked_user_id = c.created_by_user_id
  )
order by c.created_at desc;

-- name: GetCatByID :one
-- traits are fetched separately via ListCatTraits (join against the traits
-- vocabulary) rather than aggregated in here, so each trait can carry its
-- display_name without hand-rolling composite-type aggregation in sql. the
-- lateral join is the same latest-needs-help-update lookup as
-- ListCatsInBounds, unfiltered by expiry for the same reason. photo_url
-- coalesce mirrors ListCatsInBounds — see its comment. last_seen_at/
-- last_fed_at/last_water_at (issue #121's three-stat header parity gap)
-- are each the created_at of the cat's most recent update carrying that
-- structured status — one lateral per status, same shape as the nh lateral
-- above, rather than a single group-by (each status's own latest update
-- may not be the same row). soft-deleted updates are excluded, matching
-- every other read path. created_by_user_id (issue #156) lets CatsService
-- derive is_owner without a second query — a pre-#70 seed cat has it null,
-- so is_owner is always false for one, matching that no account can own it.
-- status != 'deleted' (issue #200) makes a soft-deleted cat's detail read
-- answer exactly like an unknown id (ErrCatNotFound -> 404) — deletion is
-- terminal, never relaxed even for the cat's own owner. This same predicate
-- is what makes Rename/SetCoverPhoto (both fetch ownership through this
-- query) refuse to mutate a deleted cat too, at no extra cost.
select
  c.id,
  c.name,
  st_x(c.area::geometry)::float8 as lng,
  st_y(c.area::geometry)::float8 as lat,
  c.area_label,
  coalesce(c.photo_url, m.url, '') as photo_url,
  c.created_by_user_id,
  c.created_at,
  c.last_update_at,
  nh.needs_help_category,
  nh.comment as needs_help_comment,
  nh.created_at as needs_help_created_at,
  nh.needs_help_expires_at,
  seen.last_seen_at,
  fed.last_fed_at,
  water.last_water_at
from cats c
left join media m on m.id = c.primary_photo_id
left join lateral (
  select u.needs_help_category, u.comment, u.created_at, u.needs_help_expires_at
  from updates u
  where u.cat_id = c.id and u.needs_help and u.deleted_at is null
  order by u.created_at desc, u.seq desc
  limit 1
) nh on true
left join lateral (
  select u.created_at as last_seen_at
  from updates u
  join update_statuses s on s.update_id = u.id and s.status = 'seen'
  where u.cat_id = c.id and u.deleted_at is null
  order by u.created_at desc, u.seq desc
  limit 1
) seen on true
left join lateral (
  select u.created_at as last_fed_at
  from updates u
  join update_statuses s on s.update_id = u.id and s.status = 'fed'
  where u.cat_id = c.id and u.deleted_at is null
  order by u.created_at desc, u.seq desc
  limit 1
) fed on true
left join lateral (
  select u.created_at as last_water_at
  from updates u
  join update_statuses s on s.update_id = u.id and s.status = 'water_provided'
  where u.cat_id = c.id and u.deleted_at is null
  order by u.created_at desc, u.seq desc
  limit 1
) water on true
where c.id = sqlc.arg(id) and c.status != 'deleted'
  -- issue #234: a cat owned by an account the viewer blocks answers exactly
  -- like an unknown id — the same indistinguishable-404 rule a soft-deleted
  -- cat already follows, so the response never reveals that the cat exists
  -- and was filtered. null viewer (guest, and every ownership-resolving
  -- write path, which passes none) is a no-op.
  and not exists (
    select 1 from user_blocks b
    where b.blocker_user_id = sqlc.narg(viewer_user_id)::uuid
      and b.blocked_user_id = c.created_by_user_id
  );

-- name: SetCatCoverPhoto :exec
-- issue #156: switches a cat's cover to an existing entry from its own
-- cat_media archive. CatsService verifies both ownership (created_by_user_id
-- matches the caller) and gallery membership (a GetCatMediaByCatAndMedia hit)
-- before ever issuing this update — this query itself trusts both checks
-- already happened and only writes.
update cats set primary_photo_id = sqlc.arg(primary_photo_id) where id = sqlc.arg(id);

-- name: UpdateCatName :exec
-- issue #199: owner-only rename — corrects a naming mistake made at
-- creation time without touching anything else about the cat.
-- CatsService verifies ownership (created_by_user_id matches the caller)
-- and trims/validates the name before ever issuing this update — this
-- query itself trusts both already happened and only writes.
update cats set name = sqlc.arg(name) where id = sqlc.arg(id);

-- name: CatExists :one
-- lets the updates-history endpoint 404 on an unknown cat instead of
-- silently returning an empty page indistinguishable from "no history yet".
-- status != 'deleted' (issue #200) folds a soft-deleted cat into the same
-- "doesn't exist" outcome for every caller of this query — the media
-- archive read, the updates-history read, and the ordinary/needs-help
-- update write paths all stop seeing a deleted cat as a valid target, since
-- deletion is terminal and none of those are the map/nearby/discovery/
-- detail surfaces this issue names but are still "active listing/query
-- surfaces" a deleted cat must not remain reachable through.
-- issue #234: the same choke point now also answers "not for this viewer".
-- Because the media archive, the updates history and both update-write
-- paths all gate on this one query, a blocked owner's cat stops being a
-- valid target for every one of them at once. A null viewer is a no-op, so
-- the write paths that resolve ownership (rename, cover, delete) and the
-- reports store, none of which pass a viewer, keep their current behavior.
select exists(
  select 1 from cats c
  where c.id = sqlc.arg(id)
    and c.status != 'deleted'
    and not exists (
      select 1 from user_blocks b
      where b.blocker_user_id = sqlc.narg(viewer_user_id)::uuid
        and b.blocked_user_id = c.created_by_user_id
    )
) as exists;

-- name: UpdateCatLastUpdateAt :exec
-- issue #36: run inside the same transaction as CreateUpdate/CreateUpdateStatus
-- so a new ordinary update and the cat's last_update_at commit atomically.
-- issue #38: monotonic — greatest() already ignores a null argument
-- (postgres greatest/least ignore nulls, returning null only when every
-- argument is null), so a cat's first-ever update still sets last_update_at
-- correctly. this keeps an out-of-order commit (an older update committing
-- after a newer one) from moving a cat's displayed freshness backwards.
update cats set last_update_at = greatest(last_update_at, sqlc.arg(last_update_at)) where id = sqlc.arg(id);

-- name: CreateCat :one
-- issue #70: created_by_user_id is required (resolved from the
-- authenticated bearer session, never client-supplied); created_by_device_id
-- is optional (X-Device-Token, installation/abuse-control association only).
-- area_label stays null — there is no runtime reverse-geocoding service
-- (see docs/architecture/db.md), matching how seed data is the only current
-- source of that field. last_update_at is left null: cat creation does not
-- itself post an update (docs/product/updates.md defines freshness purely
-- from actual updates), so a newly created cat starts in the same
-- long_not_seen state any never-updated cat would. idempotent by
-- construction, same shape as CreateMedia: on conflict do nothing on the
-- partial (created_by_user_id, idempotency_key) unique index means a
-- retried creation with the same key never creates a second cat — no row
-- comes back on the conflicting retry, and the caller (CatsService) looks
-- the existing row up via GetCatByIdempotencyKey instead.
-- returning computes lng/lat the same way GetCatByID/ListCatsInBounds do
-- (postgis geography has no plain Go scan type — see their comments) rather
-- than `returning *`, so CatsService never has to special-case this row's
-- shape against every other cat-reading query.
insert into cats (id, name, area, primary_photo_id, status, created_by_user_id, created_by_device_id, idempotency_key)
values (
  sqlc.arg(id),
  sqlc.narg(name),
  st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326)::geography,
  sqlc.arg(primary_photo_id),
  'active',
  sqlc.arg(created_by_user_id),
  sqlc.narg(created_by_device_id),
  sqlc.narg(idempotency_key)
)
on conflict (created_by_user_id, idempotency_key) where idempotency_key is not null do nothing
returning id, name, area_label, primary_photo_id, status, created_by_user_id, created_by_device_id, created_at, last_update_at,
  st_x(area::geometry)::float8 as lng, st_y(area::geometry)::float8 as lat;

-- name: GetCatByIdempotencyKey :one
select id, name, area_label, primary_photo_id, status, created_by_user_id, created_by_device_id, created_at, last_update_at,
  st_x(area::geometry)::float8 as lng, st_y(area::geometry)::float8 as lat
from cats
where created_by_user_id = sqlc.arg(created_by_user_id) and idempotency_key = sqlc.arg(idempotency_key);

-- name: ListNearbyCatsForDuplicateCheck :many
-- issue #70: powers GET /v1/cats/nearby, the add-cat flow's non-blocking
-- duplicate-candidate check (docs/product/cats.md, docs/product/trust.md —
-- advisory only, never blocks creation on its own). st_dwithin on the
-- geography column uses cats_area_gix the same way ListCatsInBounds' &&
-- bounding-box check does; radius_m is in meters, matching geography's
-- native unit. photo_url coalesce mirrors ListCatsInBounds/GetCatByID.
select
  c.id,
  c.name,
  coalesce(c.photo_url, m.url, '') as photo_url
from cats c
left join media m on m.id = c.primary_photo_id
where c.status = 'active'
  and st_dwithin(c.area, st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326)::geography, sqlc.arg(radius_m)::float8)
  -- issue #234: a duplicate-candidate the caller cannot open is a dead end,
  -- so a blocked owner's cats are excluded here too. Guests keep the
  -- unfiltered advisory list (null viewer matches nothing).
  and not exists (
    select 1 from user_blocks b
    where b.blocker_user_id = sqlc.narg(viewer_user_id)::uuid
      and b.blocked_user_id = c.created_by_user_id
  )
order by st_distance(c.area, st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326)::geography) asc;

-- name: ListCatsByDistance :many
-- issue #82: powers GET /v1/cats/discover?filter=nearby — every active cat,
-- nearest-first from the caller's own (lat, lng), keyset-paginated on
-- (distance_m, id) rather than offset/limit (an inserted or deleted cat
-- between two page requests must never reshuffle an already-served page,
-- and a large offset would force postgres to walk and discard every row
-- before it). The candidates CTE computes distance_m once so both the
-- keyset predicate and the order by reference the same plain column — a
-- WHERE clause can't see a SELECT list's own alias, and repeating the full
-- st_distance(...) expression three times (as ListNearbyCatsForDuplicateCheck
-- above tolerates once, for order by only) would get hard to keep in sync
-- once a keyset predicate needs it too. distance_m uses the same
-- st_distance(geography, geography) as that query, so both are backed by
-- cats_area_gix (the gist index on cats.area) the same way. photo_url
-- coalesce and the unfiltered-by-expiry needs-help lateral join mirror
-- ListCatsInBounds/GetCatByID/ListFollowedCats exactly — CatsService is the
-- one place that decides active-vs-expired, against its own injected clock.
-- after_distance_m/after_id are both null on the first page (sqlc.narg);
-- the row-comparison-shaped OR chain is the same pattern ListCatUpdates
-- already uses for its (before_created_at, before_seq) keyset, just
-- ascending instead of descending. id is an arbitrary but deterministic
-- tie-breaker for the (rare, but real once two cats share a distance)
-- equal-distance case — issue #82 requires "stable deterministic ordering
-- for equal distances".
with candidates as (
  select
    c.id,
    c.name,
    coalesce(c.photo_url, m.url, '') as photo_url,
    c.area_label,
    c.last_update_at,
    nh.needs_help_category,
    nh.comment as needs_help_comment,
    nh.created_at as needs_help_created_at,
    nh.needs_help_expires_at,
    st_distance(c.area, st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326)::geography)::float8 as distance_m
  from cats c
  left join media m on m.id = c.primary_photo_id
  left join lateral (
    select u.needs_help_category, u.comment, u.created_at, u.needs_help_expires_at
    from updates u
    where u.cat_id = c.id and u.needs_help and u.deleted_at is null
    order by u.created_at desc, u.seq desc
    limit 1
  ) nh on true
  where c.status = 'active'
    -- issue #234: same viewer-blocked-owner exclusion as the map and
    -- detail reads; null viewer (guest) is a no-op.
    and not exists (
      select 1 from user_blocks b
      where b.blocker_user_id = sqlc.narg(viewer_user_id)::uuid
        and b.blocked_user_id = c.created_by_user_id
    )
)
select id, name, photo_url, area_label, last_update_at, needs_help_category, needs_help_comment, needs_help_created_at, needs_help_expires_at, distance_m
from candidates
where sqlc.narg(after_distance_m)::float8 is null
  or distance_m > sqlc.narg(after_distance_m)::float8
  or (distance_m = sqlc.narg(after_distance_m)::float8 and id > sqlc.narg(after_id)::uuid)
order by distance_m asc, id asc
limit sqlc.arg(row_limit);

-- name: ListActiveNeedsHelpCatsByDistance :many
-- issue #82: powers GET /v1/cats/discover?filter=needs_help — the same
-- nearest-first, keyset-paginated shape as ListCatsByDistance above, plus
-- one more predicate: only a cat whose latest needs-help update is both
-- present and not yet expired, decided by comparing needs_help_expires_at
-- against sqlc.arg(now) rather than the database's own now(). now is
-- CatsService's injected clock (the same one deriveActiveAlert already
-- compares every other active-alert decision against) — passed down
-- explicitly so this query's filtering and CatsService's response-shaping
-- of the identical row always agree on what "active" meant at the same
-- instant, and so a test can hold that instant fixed at an exact expiry
-- boundary the way cats_test.go already does for deriveActiveAlert. An
-- expired needs-help update is never deleted or rewritten (see db.md) — it
-- simply stops matching this filter, exactly like it stops being anyone's
-- "latest active" alert on the map/cat-detail read paths.
with candidates as (
  select
    c.id,
    c.name,
    coalesce(c.photo_url, m.url, '') as photo_url,
    c.area_label,
    c.last_update_at,
    nh.needs_help_category,
    nh.comment as needs_help_comment,
    nh.created_at as needs_help_created_at,
    nh.needs_help_expires_at,
    st_distance(c.area, st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326)::geography)::float8 as distance_m
  from cats c
  left join media m on m.id = c.primary_photo_id
  left join lateral (
    select u.needs_help_category, u.comment, u.created_at, u.needs_help_expires_at
    from updates u
    where u.cat_id = c.id and u.needs_help and u.deleted_at is null
    order by u.created_at desc, u.seq desc
    limit 1
  ) nh on true
  where c.status = 'active'
    -- issue #234: same viewer-blocked-owner exclusion as the map and
    -- detail reads; null viewer (guest) is a no-op.
    and not exists (
      select 1 from user_blocks b
      where b.blocker_user_id = sqlc.narg(viewer_user_id)::uuid
        and b.blocked_user_id = c.created_by_user_id
    )
)
select id, name, photo_url, area_label, last_update_at, needs_help_category, needs_help_comment, needs_help_created_at, needs_help_expires_at, distance_m
from candidates
where needs_help_expires_at is not null
  and needs_help_expires_at > sqlc.arg(now)::timestamptz
  and (
    sqlc.narg(after_distance_m)::float8 is null
    or distance_m > sqlc.narg(after_distance_m)::float8
    or (distance_m = sqlc.narg(after_distance_m)::float8 and id > sqlc.narg(after_id)::uuid)
  )
order by distance_m asc, id asc
limit sqlc.arg(row_limit);

-- name: SoftDeleteCat :one
-- issue #200: owner-initiated, terminal soft delete of a cat — no restore/
-- reactivate flow exists in this version. Same atomic-conditional-update
-- shape DeleteOwnUpdate already established (docs/architecture/db.md):
-- authorization (created_by_user_id match) and the "not already deleted"
-- guard are both part of the one conditional statement, so a concurrent
-- retry can't race past either check. Returns 0 rows when the cat doesn't
-- exist, isn't owned by the caller, or is already deleted;
-- CatsService.DeleteCat disambiguates a 0-row outcome via
-- GetCatOwnershipForDelete, exactly like DeleteOwnUpdate uses
-- GetUpdateForCorrectionCheck.
update cats
set status = 'deleted'
where id = sqlc.arg(id)
  and created_by_user_id = sqlc.arg(created_by_user_id)
  and status != 'deleted'
returning id;

-- name: GetCatOwnershipForDelete :one
-- called only when SoftDeleteCat affects 0 rows, to disambiguate why:
-- unknown id (404), someone else's cat (403), or an already-deleted cat
-- (treated as an idempotent-success retry by the service, not an error).
select id, created_by_user_id, status from cats where id = sqlc.arg(id);
