-- +goose Up
-- issue #233: user-generated content reporting. a single polymorphic
-- reports table backs all three reportable surfaces (cat, update, media)
-- rather than one table per target type — the write/read shape (who
-- reported what, why, when, current review state) is identical across all
-- three. target_id carries no foreign key of its own, since it points at
-- a different table depending on target_type; referential validity is
-- enforced by the service layer at write time instead (see
-- docs/architecture/db.md).
--
-- reason is a fixed, closed check-constraint vocabulary (product-owner
-- decision on issue #233), not a data-driven table like traits — adding a
-- reason is a schema change, deliberately not a config change. 'other'
-- requires a non-empty note; every other reason leaves the note optional
-- (reports_other_requires_note_ck).
--
-- status starts 'open' and moves to 'resolved' only through direct
-- maintainer action against this table — there is no 0.4 admin endpoint
-- that writes it (out of scope, issue #233). A report never automatically
-- hides or deletes its target; nothing here references cats.status or
-- updates.deleted_at.
create table reports (
  id                uuid primary key default gen_random_uuid(),
  reporter_user_id  uuid not null references users(id),
  target_type       text not null check (target_type in ('cat', 'update', 'media')),
  target_id         uuid not null,
  reason            text not null check (reason in ('inappropriate', 'not_a_cat', 'wrong_info', 'spam', 'privacy', 'other')),
  note              text,
  status            text not null default 'open' check (status in ('open', 'resolved')),
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz,
  constraint reports_other_requires_note_ck check (
    reason != 'other' or (note is not null and length(btrim(note)) > 0)
  )
);

-- a retried/duplicate report from the same account against the same target
-- must not create a second active report — partial on status = 'open' so a
-- resolved report never blocks that account reporting the same target
-- again later.
create unique index reports_reporter_target_open_uq on reports (reporter_user_id, target_type, target_id) where status = 'open';
-- backs the future maintainer review path's "open reports, oldest first" read.
create index reports_status_created_idx on reports (status, created_at desc);

-- +goose Down
drop table reports;
