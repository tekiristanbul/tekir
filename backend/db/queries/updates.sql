-- name: CreateUpdate :one
-- kind discriminates an ordinary status update from a needs-help one (issue
-- #23); needs_help_category/needs_help_expires_at are null for an ordinary
-- update and required for a needs-help one — enforced by
-- updates_kind_fields_ck, not application code alone. created_at stays
-- caller-supplied (not now()) so seed data and tests can construct
-- deterministic, repeatable timelines and exact expiry-boundary scenarios;
-- needs_help_expires_at is likewise caller-supplied here (computed as
-- created_at + 72h at the call site, per the fixed mvp expiry) rather than
-- in sql, for the same determinism reason. upserts on id (like UpsertCat) so
-- re-running the seed script with fixed ids stays idempotent instead of
-- erroring on a duplicate key; seq is never touched by the update branch,
-- so a row's tie-breaker position is stable.
insert into updates (id, cat_id, kind, comment, created_at, needs_help_category, needs_help_expires_at)
values (
  sqlc.arg(id),
  sqlc.arg(cat_id),
  sqlc.arg(kind),
  sqlc.arg(comment),
  sqlc.arg(created_at),
  sqlc.arg(needs_help_category),
  sqlc.arg(needs_help_expires_at)
)
on conflict (id) do update set
  kind = excluded.kind,
  comment = excluded.comment,
  created_at = excluded.created_at,
  needs_help_category = excluded.needs_help_category,
  needs_help_expires_at = excluded.needs_help_expires_at
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
-- kind/needs_help_category/needs_help_expires_at (issue #23) let the client
-- render a needs-help entry distinctly from an ordinary one; active-vs-
-- expired for a needs-help entry is decided by the service layer against an
-- injected clock, never by this query's own now() or the client's own clock.
select
  u.id,
  u.kind,
  u.comment,
  u.created_at,
  u.seq,
  u.needs_help_category,
  u.needs_help_expires_at,
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
