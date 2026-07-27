-- name: ListUserOrdinaryUpdatesForBadges :many
-- issue #80: one row per ordinary update the account authored, oldest
-- first, with its full status set — feeds ProfileService.BadgeProgress's
-- oldest-to-newest threshold walk (mirrors the approved prototype's
-- badgeProgress in prototype/data.js). Soft-deleted updates (see migration
-- 00020) are excluded: a corrected-away update never counts toward a
-- threshold. needs_help rows are listed separately (see
-- ListUserNeedsHelpUpdatesForBadges) since they carry no statuses.
select
  u.cat_id,
  u.created_at,
  u.seq,
  coalesce(array_agg(s.status order by s.status) filter (where s.status is not null), '{}')::text[] as statuses
from updates u
left join update_statuses s on s.update_id = u.id
where u.author_user_id = sqlc.arg(author_user_id)
  and u.kind = 'ordinary'
  and u.deleted_at is null
group by u.id
order by u.created_at asc, u.seq asc;

-- name: ListUserNeedsHelpUpdatesForBadges :many
-- a needs-help report counts toward cats_of_istanbul's "contribute via
-- updates, media, or cat creation" condition and the profile's total
-- contribution/help counts, but never toward the status-based badges
-- (first_sighting/feeder/water_helper/neighborhood_watcher), which only
-- look at ordinary-update statuses. Needs-help updates are never
-- soft-deleted (issue #80 excludes them from correction entirely), so no
-- deleted_at filter is needed here.
select cat_id, created_at, seq
from updates
where author_user_id = sqlc.arg(author_user_id) and kind = 'needs_help'
order by created_at asc, seq asc;

-- name: ListUserCreatedCatsForBadges :many
-- a created cat counts toward cats_of_istanbul the same way a media/update
-- contribution does (docs/product/badges.md's cats_of_istanbul condition).
select id as cat_id, created_at
from cats
where created_by_user_id = sqlc.arg(created_by_user_id)
order by created_at asc;

-- name: GetCatSummariesByIDs :many
-- batch display lookup (name + resolved primary photo) for exactly the cat
-- ids the profile's recent-contributions list is about to render — never
-- the caller's full contribution history, which can be much larger. Mirrors
-- ListCatsInBounds' coalesce(photo_url, media.url) resolution so a seeded
-- and a created cat both surface the same primary_photo field.
select c.id, c.name, coalesce(c.photo_url, m.url, '') as photo_url
from cats c
left join media m on m.id = c.primary_photo_id
where c.id = any(sqlc.arg(ids)::uuid[]);
