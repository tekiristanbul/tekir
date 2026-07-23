# db

## goal

define the mvp schema backing [[api]], on postgres + postgis.

## decisions

```sql
create extension if not exists postgis;
create extension if not exists pgcrypto; -- gen_random_uuid()

create table users (
  id                 uuid primary key default gen_random_uuid(),
  phone              text unique not null,
  phone_verified_at  timestamptz not null,
  created_at         timestamptz not null default now()
);

create table devices (
  id               uuid primary key default gen_random_uuid(),
  token_hash       text unique not null,  -- sha-256 of the device_token; the raw token is never stored
  push_token       text,
  platform         text check (platform in ('ios','android')),
  user_id          uuid references users(id),
  revoked_at       timestamptz,
  created_at       timestamptz not null default now()
);

create table refresh_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references users(id),
  token_hash   text unique not null,
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now()
);

create table media (
  id                    uuid primary key default gen_random_uuid(),
  url                   text not null,
  uploaded_by_device_id uuid not null references devices(id),
  created_at            timestamptz not null default now()
);

create table cats (
  id                 uuid primary key default gen_random_uuid(),
  name               text,
  area               geography(point, 4326) not null,
  -- human-readable, display-only location label (issue #21 prototype-parity
  -- correction), e.g. "Moda Sahili, Kadıköy". nullable free text, set once
  -- at cat-creation/seed time — there is no runtime reverse-geocoding
  -- service, so this is never derived from `area` on read, and `area`
  -- itself remains the only source of truth for actual coordinates.
  area_label         text,
  primary_photo_id   uuid references media(id),
  status             text not null default 'active' check (status in ('active','inactive')),
  last_update_at     timestamptz,
  needs_help_until   timestamptz,
  created_by_device_id uuid not null references devices(id),
  created_at         timestamptz not null default now()
);
create index cats_area_gix on cats using gist (area);
create index cats_needs_help_idx on cats (needs_help_until);

-- controlled, extensible trait vocabulary (issue #21 product clarification):
-- `key` is a stable machine identity, `display_name` is mutable metadata
-- that can be re-labeled without touching any cat_traits row. not a postgres
-- enum (adding/renaming/retiring a trait must not require a migration), not
-- a free-text column (users can't type arbitrary traits), not an array
-- (loses per-trait identity/metadata). `active` retires a trait from future
-- selection without deleting it or its existing cat_traits associations.
create table traits (
  key          text primary key,
  display_name text not null,
  active       boolean not null default true,
  sort_order   int not null,
  created_at   timestamptz not null default now()
);

create table cat_traits (
  cat_id     uuid not null references cats(id),
  trait_key  text not null references traits(key),
  primary key (cat_id, trait_key)
);
create index cat_traits_trait_idx on cat_traits (trait_key);

create table updates (
  id                uuid primary key default gen_random_uuid(),
  cat_id            uuid not null references cats(id),
  comment           text,
  media_id          uuid references media(id),
  author_device_id  uuid not null references devices(id),
  created_at        timestamptz not null default now(),
  seq               bigserial
);
create index updates_cat_created_idx on updates (cat_id, created_at desc, seq desc);

-- one row per structured status on an update (an update may carry several,
-- e.g. "seen" + "water_provided"). fixed check constraint, not free text or
-- a `traits`-style vocabulary table: issue #3's product-owner decision
-- approved this exact, closed mvp vocabulary, unlike cat traits.
create table update_statuses (
  update_id  uuid not null references updates(id),
  status     text not null check (status in ('seen', 'fed', 'water_provided')),
  primary key (update_id, status)
);

-- needs-help (issue #4) is a distinct update subtype with its own lifecycle:
-- a fixed 72-hour expiry, no resolve action in the mvp, and a fixed 5-value
-- help-category vocabulary (injured/sick, food needed, water needed, unsafe
-- location, trapped) — all approved in direction and content (see
-- [[alerts]]), just not yet in schema-ready shape. deliberately not
-- modeled here yet; this is issue #4's own implementation work, not #21's.

-- outbox: the worker (see [[backend]]) polls unprocessed rows, fans each
-- one out to the cat's followers (one `notifications` row + one push per
-- follower), then sets processed_at. decoupled from `notifications` itself
-- because one update can produce many notification rows.
create table notification_outbox (
  id           uuid primary key default gen_random_uuid(),
  update_id    uuid not null references updates(id),
  cat_id       uuid not null references cats(id),
  processed_at timestamptz,
  created_at   timestamptz not null default now()
);
create index outbox_unprocessed_idx on notification_outbox (created_at) where processed_at is null;

create function enqueue_notification_outbox() returns trigger as $$
begin
  insert into notification_outbox (update_id, cat_id) values (new.id, new.cat_id);
  return new;
end;
$$ language plpgsql;

create trigger updates_enqueue_outbox
  after insert on updates
  for each row execute function enqueue_notification_outbox();

create table follows (
  device_id  uuid not null references devices(id),
  cat_id     uuid not null references cats(id),
  created_at timestamptz not null default now(),
  primary key (device_id, cat_id)
);
create index follows_cat_idx on follows (cat_id);

create table notifications (
  id         uuid primary key default gen_random_uuid(),
  device_id  uuid not null references devices(id),
  cat_id     uuid not null references cats(id),
  update_id  uuid not null references updates(id),
  read_at    timestamptz,
  created_at timestamptz not null default now(),
  unique (device_id, update_id)
);
create index notif_device_created_idx on notifications (device_id, created_at desc);
```

### design notes

- `devices.token_hash`: the client never sends a self-chosen identifier. `POST /v1/devices` (see [[api]]) generates the token server-side and returns it once; only its hash is stored, the same way a password would be. `devices.revoked_at` invalidates that one credential — it doesn't ban a person or a physical device, since nothing stops a client from calling `POST /v1/devices` again for a fresh identity. it's a mitigation for a single bad session, not an identity ban.
- `refresh_tokens`: backs the `access_token`/`refresh_token` pair in [[api]] — short-lived jwts plus a revocable, hashed refresh token, so login doesn't require a fresh otp on every app open.
- `notification_outbox` + the `updates_enqueue_outbox` trigger: this is what the notification worker in [[backend]] actually polls. it exists separately from `notifications` because one update fans out to N follower rows, and the trigger guarantees every update gets enqueued exactly once, at the database level, regardless of which code path inserted it. **delivery semantics: at-most-once, not exactly-once.** the worker must `insert into notifications (...) on conflict (device_id, update_id) do nothing returning id` for each follower *before* sending that follower's push, sending only if a row was actually returned — this guarantees no follower is ever pushed twice. it does **not** guarantee every push is sent: if the worker crashes after that insert commits but before the push actually goes out, a retry of the same outbox row hits the conflict and skips the follower, so the push is silently lost rather than retried. for mvp this small loss window is accepted as-is. a stronger guarantee (no loss) would need a recoverable per-notification delivery state (e.g. `sent_at`/`attempts` on `notifications`) and a real retry protocol, not just "the row exists" as a proxy for "the push was sent" — not worth building until it's needed.
- `update_statuses` + `updates.comment`: an update carries one or more structured statuses from the fixed mvp vocabulary (`seen`/`fed`/`water_provided`, approved on issue #3) plus an optional free-text comment. `updates.seq` is a monotonic tie-breaker for [[api]]'s keyset pagination — needed because two updates can share the same `created_at` under fast writes/seeding, and `created_at` alone wouldn't order them deterministically.
- `traits`/`cat_traits`: the trait vocabulary is data, not code — adding, relabeling, or retiring a trait is a row change, never a migration or app release. `cat_traits.trait_key` references `traits.key`, so a cat can only carry a trait that exists in the vocabulary; retiring a trait (`traits.active = false`) removes it from future selection (`ListActiveTraits`) but never deletes the row or a cat's existing association, preserving history.
- `cats.area` is a point; the ~50m "area" concept from [[cats]] is expressed at query time via `st_dwithin(area, point, 50)` rather than a separate area table — that table would add complexity with no behavior it doesn't already give.
- `cats.needs_help_until`: set to `now() + 72h` whenever a new `help_request` update lands — 72 hours is the fixed mvp expiry per the issue #4 product decision (see [[alerts]]); still implemented as a config value rather than a hardcoded literal.
- `cats.last_update_at`: refreshed on every new update, so the map's "recently updated" highlight ([[map]]) needs no join.
- `cats.status`: cats are never deleted, only marked `inactive`, per [[cats]]. the threshold for going inactive (silence duration) is undecided — left as a job/cron concern, the schema doesn't need to know the number.
- no duplicate-merge table exists yet. `nearby` lookups are computed on the fly; once a merge mechanism is decided ([[cats]]), a `cats.merged_into` column is the likely addition.
- `devices.user_id`: set once phone verification succeeds. because follows/updates are already keyed by `device_id`, linking it to a `user_id` doesn't require a data migration — history is already attached.

## open questions

- cat-inactivity threshold.
- the specific trait vocabulary content (labels/grouping) is pending product-owner review; the storage model itself (keyed, extensible, data not enum) is decided.
- needs-help's actual schema shape (lifecycle columns, category vocabulary storage) isn't modeled here yet — the product decision itself (72h expiry, 5 fixed categories, no resolve) is final; the schema work is issue #4's own follow-up, not an open product question.
- duplicate-cat merge mechanism and whether it needs a `merged_into` column or something richer.

## out of scope

- read replicas / sharding — not warranted at mvp scale.
- audit logging / soft-delete history beyond `cats.status`.
