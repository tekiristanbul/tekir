-- name: CreateUpdate :one
-- created_at is caller-supplied (not now()) so seed data and tests can
-- construct deterministic, repeatable timelines and tie-breaker scenarios.
-- upserts on id (like UpsertCat) so re-running the seed script with fixed
-- ids stays idempotent instead of erroring on a duplicate key; seq is never
-- touched by the update branch, so a row's tie-breaker position is stable.
insert into updates (id, cat_id, comment, created_at)
values (sqlc.arg(id), sqlc.arg(cat_id), sqlc.arg(comment), sqlc.arg(created_at))
on conflict (id) do update set
  comment = excluded.comment,
  created_at = excluded.created_at
returning id, seq;

-- name: CreateUpdateStatus :exec
insert into update_statuses (update_id, status)
values (sqlc.arg(update_id), sqlc.arg(status))
on conflict (update_id, status) do nothing;

-- name: ListCatUpdates :many
-- newest-first keyset pagination: (created_at, seq) both descending, seq
-- breaking ties deterministically when created_at collides. before_created_at
-- is null on the first page; the caller fetches row_limit+1 rows to detect
-- whether a next page exists, then trims the extra row before responding.
select
  u.id,
  u.comment,
  u.created_at,
  u.seq,
  coalesce(array_agg(s.status order by s.status) filter (where s.status is not null), '{}')::text[] as statuses
from updates u
left join update_statuses s on s.update_id = u.id
where u.cat_id = sqlc.arg(cat_id)
  and (
    sqlc.narg(before_created_at)::timestamptz is null
    or u.created_at < sqlc.narg(before_created_at)::timestamptz
    or (u.created_at = sqlc.narg(before_created_at)::timestamptz and u.seq < sqlc.narg(before_seq)::bigint)
  )
group by u.id
order by u.created_at desc, u.seq desc
limit sqlc.arg(row_limit)::int;
