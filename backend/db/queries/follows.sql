-- name: CreateFollow :exec
-- issue #65: account-owned. user_id is required (resolved from the
-- authenticated bearer session, never client-supplied); device_id is
-- optional (X-Device-Token, for installation/abuse-control association
-- only — it is never sufficient authorization on its own). idempotent by
-- construction: on conflict do nothing on the partial (user_id, cat_id)
-- unique index means a repeat follow for the same account/cat pair —
-- including two concurrent duplicate requests — leaves exactly one row,
-- never an error or a duplicate.
insert into follows (user_id, device_id, cat_id)
values (sqlc.arg(user_id), sqlc.narg(device_id), sqlc.arg(cat_id))
on conflict (user_id, cat_id) where user_id is not null do nothing;

-- name: DeleteFollow :exec
-- issue #65: account-scoped. idempotent: unfollowing a cat this account
-- doesn't currently follow deletes zero rows and succeeds silently rather
-- than erroring.
delete from follows where user_id = sqlc.arg(user_id) and cat_id = sqlc.arg(cat_id);

-- name: ListFollowedCats :many
-- issue #65: an account's followed cats, ordered by most recent cat
-- activity. last_update_at desc nulls last puts a cat that has never had an
-- update after every cat that has, however old — no activity is never
-- "fresher" than old activity. c.id desc is the deterministic tie-breaker
-- for equal last_update_at, including the shared-null case, since
-- last_update_at alone can't order two never-updated cats against each
-- other. joins cats (not just follows) so the response carries the same
-- cat-summary shape as the map/detail endpoints, including each cat's
-- latest needs-help update via the same unfiltered-by-expiry lateral join
-- as ListCatsInBounds/GetCatByID — the service layer decides
-- active-vs-expired against its own injected clock, never this query's own
-- now().
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
from follows f
join cats c on c.id = f.cat_id
left join media m on m.id = c.primary_photo_id
left join lateral (
  select u.needs_help_category, u.comment, u.created_at, u.needs_help_expires_at
  from updates u
  where u.cat_id = c.id and u.needs_help and u.deleted_at is null
  order by u.created_at desc, u.seq desc
  limit 1
) nh on true
where f.user_id = sqlc.arg(user_id)
order by c.last_update_at desc nulls last, c.id desc;

-- name: DeleteRedundantDeviceFollows :exec
-- issue #71: called inside AuthService.linkDevice's transaction,
-- immediately before BackfillFollowsUserID. Deletes this device's
-- not-yet-backfilled follow rows that are pure duplicates of a follow the
-- target account already owns for the same cat (from a previous device
-- link, or a direct account follow) — the account already effectively
-- follows that cat, so the duplicate carries no new information. This is
-- what keeps BackfillFollowsUserID's plain assignment below conflict-safe
-- against follows_user_cat_uq: after this delete, at most one
-- not-yet-owned row remains per cat for this device.
delete from follows f
where f.device_id = sqlc.arg(device_id)
  and f.user_id is null
  and exists (
    select 1 from follows owned
    where owned.cat_id = f.cat_id and owned.user_id = sqlc.arg(user_id)
  );

-- name: BackfillFollowsUserID :exec
-- issue #65: called inside AuthService.linkDevice's transaction, once a
-- device is linked (or re-verified as already linked) to an account.
-- idempotent — only rows still missing user_id are touched, so calling this
-- repeatedly (retries, re-verification) never reassigns an already-set
-- owner. Conflict-safe against follows_user_cat_uq only because
-- DeleteRedundantDeviceFollows already ran first in the same transaction
-- (issue #71) — a device can have at most one follow per cat
-- (follows_device_cat_uq), so at most one row here can still be
-- unbackfilled for a given cat once duplicates are gone.
update follows set user_id = sqlc.arg(user_id)
where device_id = sqlc.arg(device_id) and user_id is null;

-- name: ListNeedsHelpRecipientDevices :many
-- issue #78: the notification worker's recipient-resolution step for one
-- needs-help update. Joins account-owned follows (never device-owned ones
-- — following, like the update itself, is account state) to that
-- account's linked devices. author_user_id excludes the reporter from
-- their own notification without a separate filter step; revoked_at is
-- null excludes a device the account has since revoked; device_id is
-- distinct in case a future schema allows more than one follow row per
-- (user_id, cat_id), which follows_user_cat_uq today prevents but this
-- query shouldn't rely on. never joins on device_id — only account
-- ownership (user_id) determines who follows a cat, per [[community]]'s
-- private-following contract; devices are purely the push-delivery target.
-- push_token rides along (issue #84) so the worker can hand the fcm
-- sender a real delivery address; a null push_token device still gets its
-- in-app notifications row (the source of truth independent of push —
-- issue #84), it just isn't pushed to.
select distinct d.id as device_id, d.push_token
from follows f
join devices d on d.user_id = f.user_id
where f.cat_id = sqlc.arg(cat_id)
  and f.user_id is not null
  and f.user_id != sqlc.arg(author_user_id)
  and d.revoked_at is null;
