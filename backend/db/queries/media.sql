-- name: CreateMedia :one
-- issue #70: uploaded_by_user_id is required (resolved from the
-- authenticated bearer session, never client-supplied); uploaded_by_device_id
-- is optional (X-Device-Token, installation/abuse-control association only).
-- idempotent by construction: on conflict do nothing on the partial
-- (uploaded_by_user_id, idempotency_key) unique index means a retried
-- upload with the same key never creates a second row — no row comes back
-- (pgx.ErrNoRows) on the conflicting retry, and the caller (MediaService)
-- looks the existing row up via GetMediaByIdempotencyKey instead.
insert into media (id, object_key, url, content_type, byte_size, uploaded_by_user_id, uploaded_by_device_id, idempotency_key)
values (sqlc.arg(id), sqlc.arg(object_key), sqlc.arg(url), sqlc.arg(content_type), sqlc.arg(byte_size), sqlc.arg(uploaded_by_user_id), sqlc.narg(uploaded_by_device_id), sqlc.narg(idempotency_key))
on conflict (uploaded_by_user_id, idempotency_key) where idempotency_key is not null do nothing
returning *;

-- name: GetMediaByIdempotencyKey :one
select * from media where uploaded_by_user_id = sqlc.arg(uploaded_by_user_id) and idempotency_key = sqlc.arg(idempotency_key);

-- name: GetMediaByID :one
select * from media where id = sqlc.arg(id);
