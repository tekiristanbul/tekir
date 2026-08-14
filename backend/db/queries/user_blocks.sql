-- name: CreateBlock :exec
-- issue #234: idempotent by construction — re-blocking an account the
-- caller already blocks is a no-op that still reports success, the same
-- shape CreateFollow uses. blocker_user_id always comes from the
-- authenticated session, never from the request body; the self-block case
-- is rejected in the service before it reaches the check constraint, so
-- the constraint is the backstop, not the error message.
insert into user_blocks (blocker_user_id, blocked_user_id)
values (sqlc.arg(blocker_user_id), sqlc.arg(blocked_user_id))
on conflict (blocker_user_id, blocked_user_id) do nothing;

-- name: DeleteBlock :exec
-- unblocking is a hard delete (the follows lifecycle, not reports'
-- open/resolved one): a block carries no state worth keeping once it is
-- lifted. deleting a row that isn't there is not an error — unblock is
-- idempotent for the same reason block is.
delete from user_blocks
where blocker_user_id = sqlc.arg(blocker_user_id)
  and blocked_user_id = sqlc.arg(blocked_user_id);

-- name: ListBlockedAccounts :many
-- the caller's own block list, joined to users for the display name the
-- unblock screen shows. blocks are never public: this is the only read
-- that returns them and it is always scoped to the authenticated caller.
select b.blocked_user_id, u.display_name, b.created_at
from user_blocks b
join users u on u.id = b.blocked_user_id
where b.blocker_user_id = sqlc.arg(blocker_user_id)
order by b.created_at desc;
