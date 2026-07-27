-- +goose Up
-- issue #71: post-merge review of #68 found migration 00016's bulk backfill
-- (and the equivalent runtime query, AuthService.linkDevice's
-- BackfillFollowsUserID) assigned user_id to every device-owned follows row
-- unconditionally. Whenever one account's multiple linked devices — or a
-- device plus a prior direct account follow — already followed the same
-- cat, that violates follows_user_cat_uq. This repairs any such
-- conflicting state a run of that unfixed logic could have left behind.
-- Purely a data repair, safe to run unconditionally: a no-op wherever no
-- conflict exists, and idempotent if re-run. See db/queries/follows.sql's
-- DeleteRedundantDeviceFollows for the matching runtime-path fix, so a
-- freshly-linked device can never reintroduce this conflict going forward.
--
-- for each (cat_id, target account) group of not-yet-backfilled
-- device-owned rows: if that account already has a user_id-owned row for
-- this cat (from a previous partial backfill or a direct account follow),
-- every candidate row is a pure duplicate — delete them all. Otherwise keep
-- exactly one (the earliest by created_at, then device_id, for
-- determinism) to promote below, and delete the rest. Either way, the
-- fact that the account follows the cat is preserved — never fully lost,
-- only deduplicated — and the following UPDATE can no longer violate the
-- unique index, since at most one qualifying row per (cat_id, user_id)
-- remains. follows has no surrogate id column — device_id/cat_id (the
-- table's natural key, unique per follows_device_cat_uq) identify a row
-- instead.
with candidates as (
  select
    f.device_id,
    f.cat_id,
    d.user_id as target_user_id,
    row_number() over (
      partition by f.cat_id, d.user_id
      order by f.created_at, f.device_id
    ) as rn,
    exists (
      select 1 from follows owned
      where owned.cat_id = f.cat_id and owned.user_id = d.user_id
    ) as already_owned
  from follows f
  join devices d on d.id = f.device_id
  where f.user_id is null and d.user_id is not null
)
delete from follows f
using candidates c
where f.device_id = c.device_id
  and f.cat_id = c.cat_id
  and (c.already_owned or c.rn > 1);

update follows f
set user_id = d.user_id
from devices d
where f.device_id = d.id
  and d.user_id is not null
  and f.user_id is null;

-- +goose Down
-- data-repair only, no schema change to reverse. The rows this deleted
-- were exact duplicates of a row that either already existed or that this
-- same migration produced by promotion — recreating them would only
-- reintroduce the conflict this migration exists to remove, not restore
-- any information actually lost.
select 1;
