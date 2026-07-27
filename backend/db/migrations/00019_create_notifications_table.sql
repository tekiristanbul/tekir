-- +goose Up
-- issue #78: the notification worker sketched in 00008's comment ("the
-- worker and the notifications/follows tables it reads are a separate,
-- later slice") lands here. `notifications` is the per-device delivery
-- record the worker inserts while draining `notification_outbox`: one row
-- per (device, update) it decided to fan the outbox row out to, distinct
-- from `notification_outbox` itself since one outbox row (one needs-help
-- update) can produce many notifications rows (one per follower device).
--
-- unique (device_id, update_id) is the delivery-dedup boundary: the worker
-- does `insert ... on conflict (device_id, update_id) do nothing returning
-- id` and only calls the notification sender when a row actually comes
-- back, so a retried or concurrently-run dispatch can never double-send to
-- the same device for the same update (see docs/architecture/db.md).
create table notifications (
  id         uuid primary key default gen_random_uuid(),
  device_id  uuid not null references devices(id),
  cat_id     uuid not null references cats(id),
  update_id  uuid not null references updates(id),
  read_at    timestamptz,
  created_at timestamptz not null default now(),
  constraint notifications_device_update_uq unique (device_id, update_id)
);

-- backs GET /v1/me/notifications' keyset pagination (device_id resolved
-- from the caller's linked devices, newest-first) the same way
-- updates_needs_help_idx (00006) backs the cat-timeline read path.
create index notif_device_created_idx on notifications (device_id, created_at desc);

-- +goose Down
drop table notifications;
