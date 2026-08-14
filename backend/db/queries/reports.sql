-- name: CreateReport :one
-- issue #233: reporter_user_id/target_type/target_id/reason are all
-- validated by the service layer before this runs (target existence,
-- closed reason vocabulary, other-requires-note). idempotent by
-- construction, mirroring CreateMedia/CreateCat's own idempotency-key
-- pattern: on conflict do nothing on the partial (reporter_user_id,
-- target_type, target_id) where status = 'open' unique index means a
-- retried/duplicate report never creates a second active row — no row
-- comes back (pgx.ErrNoRows) on the conflicting retry, and the caller
-- (ReportsService) looks the existing open report up via
-- GetOpenReportByReporterAndTarget instead.
insert into reports (id, reporter_user_id, target_type, target_id, reason, note)
values (sqlc.arg(id), sqlc.arg(reporter_user_id), sqlc.arg(target_type), sqlc.arg(target_id), sqlc.arg(reason), sqlc.narg(note))
on conflict (reporter_user_id, target_type, target_id) where status = 'open' do nothing
returning *;

-- name: GetOpenReportByReporterAndTarget :one
-- resolves a retried/duplicate POST /v1/reports (same reporter, same
-- target, still open) to the report it already created — mirrors
-- GetCatByIdempotencyKey/GetMediaByIdempotencyKey's own conflict-recovery
-- shape.
select * from reports
where reporter_user_id = sqlc.arg(reporter_user_id)
  and target_type = sqlc.arg(target_type)
  and target_id = sqlc.arg(target_id)
  and status = 'open';
