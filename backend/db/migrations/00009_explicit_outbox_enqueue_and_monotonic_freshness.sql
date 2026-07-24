-- +goose Up
-- issue #38: post-merge correctness follow-up to #36/pr #37. two problems
-- with what 00008 shipped:
--
-- 1. `updates_enqueue_outbox` fires on every insert into `updates`, not just
--    a real POST /v1/cats/{cat_id}/updates write — seed fixtures, tests, and
--    any other direct repository insert all enqueue outbox work for events
--    that never happened. the fix moves enqueueing into the application
--    layer: Store.CreateOrdinaryUpdate now inserts the outbox row itself,
--    inside the same transaction, so only that call path ever produces one.
-- 2. `notification_outbox.update_id` had no uniqueness guarantee, so
--    retrying or accidentally repeating an enqueue could duplicate work.

drop trigger updates_enqueue_outbox on updates;
drop function enqueue_notification_outbox();

-- clean up outbox rows the old trigger created for updates that predate
-- (or bypass) the authenticated ordinary-write path: without an
-- author_device_id, an update was never a real POST .../updates call, so
-- its outbox row is synthetic notification work that must not be delivered.
-- rows for an attributed update are untouched.
delete from notification_outbox
using updates
where notification_outbox.update_id = updates.id
  and updates.author_device_id is null;

alter table notification_outbox
  add constraint notification_outbox_update_id_key unique (update_id);

-- +goose Down
alter table notification_outbox drop constraint notification_outbox_update_id_key;

-- +goose StatementBegin
create function enqueue_notification_outbox() returns trigger as $$
begin
  insert into notification_outbox (update_id, cat_id) values (new.id, new.cat_id);
  return new;
end;
$$ language plpgsql;
-- +goose StatementEnd

create trigger updates_enqueue_outbox
  after insert on updates
  for each row execute function enqueue_notification_outbox();

-- the rows this migration deleted (synthetic outbox work for unattributed
-- updates) cannot be un-deleted; they were never valid notification work in
-- the first place, so the down migration restores schema/behavior, not data.
