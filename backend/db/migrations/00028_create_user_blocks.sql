-- +goose Up
-- issue #234: account-to-account blocking. a block is a plain directed
-- edge (blocker -> blocked); it carries no state beyond its existence, so
-- unblocking deletes the row rather than flagging it — the same lifecycle
-- follows already uses, and deliberately not reports' append-only
-- open/resolved shape, because the product decision is that blocking is
-- reversible and leaves nothing behind.
--
-- the block is the authority for *visibility*, never for deletion: nothing
-- here touches cats.status, updates.deleted_at, or any media row. what a
-- block hides is resolved at read time by every cat-returning query, keyed
-- on cats.created_by_user_id (the cat's owner), not on who authored an
-- individual update or uploaded an individual media item — see
-- docs/architecture/db.md.
create table user_blocks (
  blocker_user_id  uuid not null references users(id),
  blocked_user_id  uuid not null references users(id),
  created_at       timestamptz not null default now(),
  primary key (blocker_user_id, blocked_user_id),
  constraint user_blocks_no_self_block_ck check (blocker_user_id != blocked_user_id)
);

-- every filtered read asks the same question — "does this viewer block this
-- cat's owner?" — so the primary key already serves them. this index backs
-- the other direction, which only the account's own block list needs.
create index user_blocks_blocked_idx on user_blocks (blocked_user_id);

-- +goose Down
drop table user_blocks;
