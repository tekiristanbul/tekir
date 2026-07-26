-- name: CreateOtpCode :one
insert into otp_codes (id, phone, code_hash, max_attempts, expires_at)
values (sqlc.arg(id), sqlc.arg(phone), sqlc.arg(code_hash), sqlc.arg(max_attempts), sqlc.arg(expires_at))
returning id, created_at;

-- name: GetLatestOtpCode :one
-- the most recently issued code for a phone number, regardless of whether
-- it's already consumed or expired — the service layer decides validity
-- against its own injected clock so behavior stays deterministically
-- testable (issue #58).
select id, phone, code_hash, attempts, max_attempts, expires_at, consumed_at, created_at
from otp_codes
where phone = sqlc.arg(phone)
order by created_at desc
limit 1;

-- name: IncrementOtpAttempts :exec
update otp_codes set attempts = attempts + 1 where id = sqlc.arg(id);

-- name: ConsumeOtpCode :exec
update otp_codes set consumed_at = sqlc.arg(consumed_at) where id = sqlc.arg(id);
