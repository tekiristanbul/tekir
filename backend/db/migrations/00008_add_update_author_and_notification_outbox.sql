-- +goose Up
-- issue #36: POST /v1/cats/{cat_id}/updates (ordinary text-only status
-- update). two schema pieces this write path needs that weren't required
-- by any read-only slice so far.

-- author_device_id is nullable, not the `not null references devices(id)`
-- sketched in docs/architecture/db.md: every update row seeded so far (and
-- every needs-help row, since issue #23/#4's write path still doesn't
-- exist) predates authenticated writes and has no real device to point at.
-- mirrors the same deferral already used for cats.created_by_device_id
-- (00003) and devices.user_id (00007) — the column exists once its write
-- path does, populated in full from then on, rather than forcing a
-- fabricated backfill value onto rows that were never actually authored by
-- a device. the application layer (not a constraint) guarantees every row
-- inserted through this issue's endpoint carries it.
alter table updates add column author_device_id uuid references devices(id);

-- outbox: the notification worker (see [[backend]], not implemented yet)
-- polls unprocessed rows and fans each one out to the cat's followers.
-- decoupled from `notifications` itself since one update can produce many
-- follower rows. this issue only needs the trigger that keeps the outbox
-- populated — the worker and the `notifications`/`follows` tables it reads
-- are a separate, later slice.
create table notification_outbox (
  id           uuid primary key default gen_random_uuid(),
  update_id    uuid not null references updates(id),
  cat_id       uuid not null references cats(id),
  processed_at timestamptz,
  created_at   timestamptz not null default now()
);
create index outbox_unprocessed_idx on notification_outbox (created_at) where processed_at is null;

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

-- +goose Down
drop trigger updates_enqueue_outbox on updates;
drop function enqueue_notification_outbox();
drop table notification_outbox;
alter table updates drop column author_device_id;
