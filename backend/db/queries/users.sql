-- name: CreateUser :one
-- creates a new account for a normalized phone number. the unique
-- constraint on users.phone is what makes concurrent otp verification for
-- the same number resolve to exactly one account: the losing concurrent
-- insert fails with a unique violation and the caller falls back to
-- GetUserByPhone (issue #58). display_name is null at creation — set
-- afterwards via UpdateUserDisplayName once the new-account minimum-profile
-- step collects it.
insert into users (id, phone, phone_verified_at)
values (sqlc.arg(id), sqlc.arg(phone), sqlc.arg(phone_verified_at))
returning id, phone, phone_verified_at, created_at, display_name;

-- name: GetUserByPhone :one
select id, phone, phone_verified_at, created_at, display_name
from users
where phone = sqlc.arg(phone);

-- name: GetUserByID :one
select id, phone, phone_verified_at, created_at, display_name
from users
where id = sqlc.arg(id);

-- name: UpdateUserDisplayName :exec
update users set display_name = sqlc.arg(display_name) where id = sqlc.arg(id);
