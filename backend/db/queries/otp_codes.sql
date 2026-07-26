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

-- name: ConsumeOtpCodeIfValid :one
-- atomic compare-and-set (code review fix, issue #58): the previous
-- read-then-unconditional-update let two concurrent verifications of the
-- same code both pass validation in application code before either wrote
-- consumed_at, so both could proceed to account linking and session
-- issuance. this single statement re-evaluates every validity predicate
-- (still the phone's latest code, unconsumed, unexpired, attempts
-- remaining) atomically against the row's current committed state; a
-- concurrent loser's update commits after the winner's and matches zero
-- rows, since consumed_at is no longer null by the time it runs. the
-- "still the latest" subquery preserves the existing "only the most
-- recently issued code is ever checked" behavior — a race can't smuggle in
-- consumption of a superseded code.
update otp_codes as o
set consumed_at = sqlc.arg(consumed_at)
where o.id = sqlc.arg(id)
  and o.code_hash = sqlc.arg(code_hash)
  and o.consumed_at is null
  and o.expires_at > sqlc.arg(now)
  and o.attempts < o.max_attempts
  and o.id = (
    select latest.id from otp_codes as latest
    where latest.phone = sqlc.arg(phone)
    order by latest.created_at desc
    limit 1
  )
returning o.id;
