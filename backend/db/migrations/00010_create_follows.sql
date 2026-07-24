-- +goose Up
-- issue #44: device-owned cat follows/favorites — sketched in
-- docs/architecture/db.md since issue #38, this migration is what actually
-- creates it. following is device-owned, not user-owned (docs/product/
-- trust.md: following works without login), and stays device-owned even
-- after a device is later linked to an account — devices.user_id (00007's
-- future column) attaches to the existing device_id, so no follows row
-- ever needs to move or be rewritten when that linking happens.
--
-- (device_id, cat_id) as the primary key is what makes follow/unfollow
-- naturally idempotent: a repeat follow is
-- `insert ... on conflict (device_id, cat_id) do nothing`, and postgres
-- serializes two concurrent duplicate follow inserts on that same key, so
-- only one row ever survives either way.
create table follows (
  device_id  uuid not null references devices(id),
  cat_id     uuid not null references cats(id),
  created_at timestamptz not null default now(),
  primary key (device_id, cat_id)
);

-- supports the notification worker's future "which devices follow cat X"
-- fan-out lookup (see [[backend]]); matches the index already sketched
-- alongside this table in docs/architecture/db.md.
create index follows_cat_idx on follows (cat_id);

-- +goose Down
drop table follows;
