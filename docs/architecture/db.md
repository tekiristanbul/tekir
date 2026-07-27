# db

## goal

define the mvp schema backing [[api]], on postgres + postgis.

## decisions

```sql
create extension if not exists postgis;
create extension if not exists pgcrypto; -- gen_random_uuid()

-- implemented (migration 00011, issue #58).
create table users (
  id                 uuid primary key default gen_random_uuid(),
  phone              text unique not null,
  phone_verified_at  timestamptz not null,
  created_at         timestamptz not null default now(),
  display_name       text -- implemented (migration 00015, issue #58); nullable, see design notes below
);

create table devices (
  id               uuid primary key default gen_random_uuid(),
  token_hash       text unique not null,  -- sha-256 of the device_token; the raw token is never stored
  push_token       text,
  platform         text not null check (platform in ('ios', 'android', 'web')),
  revoked_at       timestamptz,
  created_at       timestamptz not null default now(),
  user_id          uuid references users(id) -- implemented (migration 00012, issue #58); nullable, see design notes below
);

-- implemented (migration 00013, issue #58).
create table refresh_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references users(id),
  token_hash   text unique not null,
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now()
);

-- implemented (migration 00014, issue #58): one-time phone-verification
-- codes. only the sha-256 hash of the code, bound to its phone number, is
-- stored — never the plaintext. the service layer decides expiry/attempt-
-- limit outcomes against its own injected clock, never this table's own
-- now(), so behavior stays deterministically testable (see [[backend]]).
create table otp_codes (
  id           uuid primary key default gen_random_uuid(),
  phone        text not null,
  code_hash    text not null,
  attempts     int not null default 0,
  max_attempts int not null default 5,
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  created_at   timestamptz not null default now()
);

-- implemented (migration 00017, issue #70): uploaded_by_user_id is required
-- from the start (unlike cats.created_by_device_id/media's own earlier
-- sketch here, which predated any account model) — there is no pre-#70
-- media data to migrate, so this never needed the users-first,
-- devices-nullable deferral pattern migration 00016 used for follows/
-- updates. object_key/content_type/byte_size are what the provider-neutral
-- ObjectStore boundary and server-side media validation need (see
-- [[backend]]); idempotency_key backs POST /v1/media's Idempotency-Key
-- header — see design notes below.
create table media (
  id                    uuid primary key default gen_random_uuid(),
  object_key            text not null,
  url                   text not null,
  content_type          text not null,
  byte_size             int not null,
  uploaded_by_user_id   uuid not null references users(id),
  uploaded_by_device_id uuid references devices(id),
  idempotency_key       text,
  created_at            timestamptz not null default now()
);
create unique index media_user_idempotency_uq on media (uploaded_by_user_id, idempotency_key) where idempotency_key is not null;

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
  -- photo_url (issue #7) is seed-only: every cat created through
  -- POST /v1/cats (issue #70) instead sets primary_photo_id, referencing
  -- its required media row. read paths coalesce(photo_url, media.url) so
  -- both a seeded and a created cat resolve the same primary_photo field —
  -- see design notes below.
  photo_url          text,
  primary_photo_id   uuid references media(id),
  status             text not null default 'active' check (status in ('active','inactive')),
  last_update_at     timestamptz,
  created_by_device_id uuid references devices(id), -- nullable: see design notes below
  created_by_user_id  uuid references users(id), -- implemented (migration 00017, issue #70): see design notes below
  idempotency_key     text, -- backs POST /v1/cats' Idempotency-Key header — see design notes below
  created_at         timestamptz not null default now()
);
create index cats_area_gix on cats using gist (area);
create unique index cats_user_idempotency_uq on cats (created_by_user_id, idempotency_key) where idempotency_key is not null;

-- dormant legacy storage (issue #21/#23, superseded by issue #42): permanent
-- cat traits are no longer part of the mvp surface — behavioral
-- observations belong in update comments instead (see [[updates]]). these
-- tables and any existing rows are kept as-is (never dropped or rewritten),
-- but no current code path writes to them or reads them back to a client;
-- traits.sql.go's repository queries remain solely so the dormant data
-- stays reachable for a future migration/audit, not for live api use.
--
-- controlled, extensible trait vocabulary (issue #21 product clarification):
-- `key` is a stable machine identity, `display_name` is mutable metadata
-- that can be re-labeled without touching any cat_traits row. not a postgres
-- enum (adding/renaming/retiring a trait must not require a migration), not
-- a free-text column (users can't type arbitrary traits), not an array
-- (loses per-trait identity/metadata). `active` retires a trait from future
-- selection without deleting it or its existing cat_traits associations.
-- `group_key` (issue #23) is the future grouped-picker's section — nullable
-- since assigning a group is a data concern, not a schema-level requirement.
create table trait_groups (
  key          text primary key,
  display_name text not null,
  sort_order   int not null
);

create table traits (
  key          text primary key,
  display_name text not null,
  group_key    text references trait_groups(key),
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

-- `kind` (issue #4/#23) discriminates an ordinary status update from a
-- needs-help one sharing this same table — one history, two subtypes,
-- rather than a separate alerts table. needs_help_category/
-- needs_help_expires_at are only ever populated together with kind =
-- 'needs_help' (see updates_kind_fields_ck below); expires_at is persisted
-- explicitly (server-computed as created_at + 72h at write time) rather
-- than derived from created_at on every read, so a future change to the
-- expiry window can't silently reinterpret an already-created alert.
create table updates (
  id                     uuid primary key default gen_random_uuid(),
  cat_id                 uuid not null references cats(id),
  kind                   text not null default 'ordinary' check (kind in ('ordinary', 'needs_help')),
  comment                text,
  media_id               uuid references media(id),
  author_device_id       uuid not null references devices(id), -- as implemented (migration 00008), this column is nullable: see design notes below
  author_user_id         uuid references users(id), -- implemented (migration 00016, issue #65): see design notes below
  created_at             timestamptz not null default now(),
  seq                    bigserial,
  needs_help_category    text check (
    needs_help_category in ('injured_or_sick', 'food_needed', 'water_needed', 'unsafe_location', 'trapped')
  ),
  needs_help_expires_at  timestamptz,
  -- implemented (migration 00020, issue #80): back the 10-minute
  -- correction window. updated_at is set only by a successful PATCH;
  -- deleted_at is a soft-delete tombstone, never a real row removal — see
  -- design notes below.
  updated_at             timestamptz,
  deleted_at             timestamptz,
  constraint updates_kind_fields_ck check (
    (kind = 'ordinary' and needs_help_category is null and needs_help_expires_at is null)
    or
    (kind = 'needs_help' and needs_help_category is not null and needs_help_expires_at is not null)
  )
);
create index updates_cat_created_idx on updates (cat_id, created_at desc, seq desc);
create index updates_needs_help_idx on updates (cat_id, created_at desc, seq desc) where kind = 'needs_help';
-- implemented (migration 00020, issue #80): serves both badge derivation's
-- oldest-first walk over one account's own ordinary, non-deleted updates
-- and the correction/delete write path's own lookups.
create index updates_author_correction_idx on updates (author_user_id, created_at)
  where kind = 'ordinary' and deleted_at is null;

-- one row per structured status on an update (an update may carry several,
-- e.g. "seen" + "water_provided"). fixed check constraint, not free text or
-- a `traits`-style vocabulary table: issue #3's product-owner decision
-- approved this exact, closed mvp vocabulary, unlike cat traits. intended
-- to be populated only for an ordinary update — a needs-help update
-- carries a category instead (see updates.needs_help_category above) — but
-- that pairing, and issue #3's "at least one status per ordinary update"
-- rule, aren't enforced at this layer yet; see the open question below.
create table update_statuses (
  update_id  uuid not null references updates(id),
  status     text not null check (status in ('seen', 'fed', 'water_provided')),
  primary key (update_id, status)
);

-- outbox: the notifier worker (cmd/notifier, see [[backend]]) polls
-- unprocessed rows; a needs-help row fans out to the cat's followers (one
-- `notifications` row + one push per follower device), then sets
-- processed_at — an ordinary-update row is marked processed with no
-- fan-out at all (mvp only ever notifies for needs-help, see
-- [[notifications]]). decoupled from `notifications` itself because one
-- update can produce many notification rows.
--
-- this table and updates.author_device_id are implemented as of migration
-- 00008 (issue #36's write path); the worker that polls this table, and the
-- notifications table it reads (migration 00019, issue #78), are now
-- implemented too — see design notes below. `follows` below is implemented
-- (migration 00010, issue #44), but nothing populates this outbox for a
-- follow/unfollow itself — only POST /v1/cats/{cat_id}/updates and
-- POST /v1/cats/{cat_id}/needs-help ever enqueue outbox work.
-- 00008 originally enqueued a row via a table-wide `updates` insert trigger;
-- migration 00009 (issue #38) removed it in favor of an explicit enqueue
-- inside Store.CreateOrdinaryUpdate's (and, since issue #78,
-- Store.CreateNeedsHelpUpdate's) transaction — see design notes.
create table notification_outbox (
  id           uuid primary key default gen_random_uuid(),
  update_id    uuid not null references updates(id) unique,
  cat_id       uuid not null references cats(id),
  processed_at timestamptz,
  created_at   timestamptz not null default now()
);
create index outbox_unprocessed_idx on notification_outbox (created_at) where processed_at is null;

-- implemented as of migration 00010 (issue #44), extended by migration
-- 00016 (issue #65) — see design notes below.
create table follows (
  device_id  uuid references devices(id), -- nullable as of migration 00016; not null before it
  user_id    uuid references users(id), -- added by migration 00016
  cat_id     uuid not null references cats(id),
  created_at timestamptz not null default now(),
  constraint follows_owner_ck check (device_id is not null or user_id is not null)
);
create index follows_cat_idx on follows (cat_id);
create unique index follows_device_cat_uq on follows (device_id, cat_id) where device_id is not null;
create unique index follows_user_cat_uq on follows (user_id, cat_id) where user_id is not null;

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

- `devices.token_hash`: the client never sends a self-chosen identifier. `POST /v1/devices` (see [[api]]) generates the token server-side and returns it once; only its hash (sha-256, lower-hex) is stored, the same way a password would be. `devices.revoked_at` invalidates that one credential — it doesn't ban a person or a physical device, since nothing stops a client from calling `POST /v1/devices` again for a fresh identity. it's a mitigation for a single bad session, not an identity ban. `platform` accepts `'ios'`, `'android'`, and `'web'` (`'web'` is required because the flutter application has a web target). `user_id` was intentionally absent from the original migration (00007) and added by migration 00012 (issue #58) once the `users` table existed.
- `refresh_tokens` (implemented, migration 00013, issue #58): backs the `access_token`/`refresh_token` pair in [[api]] — short-lived jwts plus a revocable, hashed refresh token, so login doesn't require a fresh otp on every app open. refreshing rotates: the presented row is revoked and a new one inserted, rather than reused, so a stolen-and-replayed refresh token stops working the moment the legitimate client rotates it.
- `otp_codes` (implemented, migration 00014, issue #58): `code_hash` is bound to its phone number (`sha256(phone + ":" + code)`), so the same digit string never collides across two different numbers. `attempts`/`max_attempts` bound brute-force guessing per issued code; `consumed_at` prevents a code from ever verifying twice (replay prevention). expiry and attempt-limit decisions are made by the service layer against its own injected clock, never this table's own `now()`.
- `users.display_name` (implemented, migration 00015, issue #58): the approved prototype's new-account step ("Görünen adını seç") collects this before finishing sign-in. null at account creation — `POST /v1/auth/otp/verify` never sets it, only reports `is_new_account` (see [[api]]) so the client knows to collect it; `PATCH /v1/me` (Bearer) sets it afterward. no uniqueness constraint, matching the prototype (two accounts may share a display name).
- `updates.author_device_id`: implemented (migration 00008) as nullable, not the `not null` sketched above — every update row seeded before issue #36's write path existed (and every needs-help row, since issue #23/#4's own write path still doesn't exist) predates authenticated writes and has no real device to attribute. mirrors the same deferral already used for `cats.created_by_device_id` (00003) and `devices.user_id` (00007): the column exists once its write path does, populated in full from then on, rather than forcing a fabricated backfill value onto rows never actually authored by a device. `POST /v1/cats/{cat_id}/updates` ([[api]]) is the only code path that populates it today — but not always: `X-Device-Token` is optional as of issue #65 (`OptionalDeviceToken`), so a bearer-only call with no device token leaves it null, same as any pre-#65 row. `updates.author_user_id` (migration 00016, issue #65) is the same deferral pattern one level up: nullable, populated by that same write path once it started resolving the authenticated account from `Authorization: Bearer` instead of only `X-Device-Token`, and backfilled onto any pre-existing device-authored row the moment its device links to an account (see the `devices.user_id` note below) — `author_device_id` itself is never cleared or rewritten by that backfill, only `author_user_id` is added alongside it.
- `notification_outbox`: this is what `cmd/notifier`'s `NotificationService.DispatchPending` (issue #78, [[backend]]) actually polls. it exists separately from `notifications` because one update fans out to N follower rows. as of migration 00009 (issue #38), the outbox row is enqueued explicitly inside `Store.CreateOrdinaryUpdate`'s (and, since #78, `Store.CreateNeedsHelpUpdate`'s) own transaction — not by a table-wide `updates` insert trigger — so only those two authenticated write paths ever produce outbox work; a seed fixture, test, or any other direct `CreateUpdate` call never does. `notification_outbox.update_id` is unique, so retrying (or otherwise repeating) an enqueue for the same update fails loudly and rolls the whole write back instead of duplicating it. `DispatchPending` claims a batch with `select ... for update skip locked`, so more than one worker process can poll concurrently without two of them claiming (and fanning out) the same row — an ordinary-update row is marked processed with no recipients at all; only a needs-help row resolves followers and fans out. **delivery semantics: at-most-once, not exactly-once.** the worker inserts into `notifications (...) on conflict (device_id, update_id) do nothing returning id` for each follower device *before* sending that device's push, sending only if a row was actually returned — this guarantees no device is ever pushed twice, even under a retried dispatch or a second worker racing the first. it does **not** guarantee every push is sent: if the worker crashes after that insert commits but before the push actually goes out, a retry of the same outbox row hits the conflict and skips the device, so the push is silently lost rather than retried. for mvp this small loss window is accepted as-is. a stronger guarantee (no loss) would need a recoverable per-notification delivery state (e.g. `sent_at`/`attempts` on `notifications`) and a real retry protocol, not just "the row exists" as a proxy for "the push was sent" — not worth building until it's needed.
- `update_statuses` + `updates.comment`: an update carries one or more structured statuses from the fixed mvp vocabulary (`seen`/`fed`/`water_provided`, approved on issue #3) plus an optional free-text comment. `updates.seq` is a monotonic tie-breaker for [[api]]'s keyset pagination — needed because two updates can share the same `created_at` under fast writes/seeding, and `created_at` alone wouldn't order them deterministically.
- `follows`: originally implemented (migration 00010, issue #44) as a bare `(device_id, cat_id)` composite primary key — device-owned, no account involved. migration 00016 (issue #65) moved authorization for new follow writes onto the account: `device_id` was relaxed to nullable, `user_id` was added, the composite primary key was replaced by `follows_owner_ck` (`device_id is not null or user_id is not null`) plus two **partial** unique indexes — `follows_device_cat_uq on (device_id, cat_id) where device_id is not null` (keeps every pre-#65 row's uniqueness/idempotency guarantee unchanged) and `follows_user_cat_uq on (user_id, cat_id) where user_id is not null` (the new idempotency key: `CreateFollow` now inserts with `on conflict (user_id, cat_id) where user_id is not null do nothing`). a new follow write always sets `user_id` (resolved from `Authorization: Bearer`, never client-supplied) and optionally `device_id` (from `X-Device-Token`, for installation/abuse-control association only). `follows_cat_idx` backs `ListNeedsHelpRecipientDevices`'s "who follows this cat" fan-out query (issue #78) without forcing a sequential scan; `GET /v1/me/follows`'s own now-account-scoped listing is served by `follows_user_cat_uq`. rows are never deleted except by an explicit unfollow. a pre-#65 device-owned row (`device_id` set, `user_id` null) is not silently reassigned by linking — instead, `AuthService.linkDevice` explicitly backfills its `user_id` the moment the owning device links to an account (see the `devices.user_id` note below), so a guest's follows survive login and immediately surface under the account, without ever changing which device performed the original follow.
- `traits`/`cat_traits`/`trait_groups` (dormant legacy storage, issue #42): the trait vocabulary is data, not code — adding, relabeling, regrouping, or retiring a trait is a row change, never a migration or app release. `cat_traits.trait_key` references `traits.key`, so a cat can only carry a trait that exists in the vocabulary; retiring a trait (`traits.active = false`) removes it from future selection (`ListActiveTraits`) but never deletes the row or a cat's existing association, preserving history. `traits.group_key` is nullable — an ungrouped trait is still valid vocabulary, just not sorted into a picker section; `ListActiveTraits`/`ListCatTraits` order group-then-trait, with an ungrouped trait sorting after every grouped one. as of issue #42, none of this is reachable from the mvp api or seed data any more — the tables, their existing rows, and the repository queries that read them stay in place untouched, but no application code path writes new rows or serves them to a client.
- `cats.area` is a point; the ~50m "area" concept from [[cats]] is expressed at query time via `st_dwithin(area, point, 50)` rather than a separate area table — that table would add complexity with no behavior it doesn't already give.
- `updates.kind`/`needs_help_category`/`needs_help_expires_at` + `updates_kind_fields_ck` (issue #4/#23): needs-help is modeled as an explicit subtype of the same `updates` history, not a separate table — mirroring how `update_statuses` already models ordinary updates as a closed, fixed vocabulary rather than free text. the check constraint makes an invalid combination (an ordinary update carrying a category, or a needs-help update missing one) unrepresentable, so the invariant holds regardless of which code path performs the insert. `needs_help_expires_at` is always `created_at + 72h` (the fixed issue #4 expiry), computed once at write time and persisted, not derived from `created_at` on every read. "active" is never a separately stored boolean: the map/cat-detail read paths look up a cat's latest `needs_help` update (via `updates_needs_help_idx`) and the service layer — against an injected clock, so this stays deterministically testable — decides whether `needs_help_expires_at` is still in the future. an expired needs-help row is never deleted or rewritten; it simply stops being anyone's "latest active" alert, exactly like [[alerts]]'s "72 hours removes emphasis, not the record" decision.
- a prior draft of this schema kept a denormalized `cats.needs_help_until` for the same fact — dropped (issue #23) once it became clear that duplicating "the latest needs-help update's expiry" onto `cats` risked drifting from `updates.needs_help_expires_at`, the actual source of truth, without saving a meaningful join at this scale.
- `cats.last_update_at`: refreshed on every new update, so the map's "recently updated" highlight ([[map]]) needs no join.
- `cats.status`: cats are never deleted, only marked `inactive`, per [[cats]]. the threshold for going inactive (silence duration) is undecided — left as a job/cron concern, the schema doesn't need to know the number.
- no duplicate-merge table exists yet. `nearby` lookups are computed on the fly; once a merge mechanism is decided ([[cats]]), a `cats.merged_into` column is the likely addition.
- `media` (implemented, migration 00017, issue #70): created for the first time by this migration — there was no pre-#70 media data, so unlike `cats.created_by_device_id`/`updates.author_device_id`, `uploaded_by_user_id` is `not null` from the start; `uploaded_by_device_id` is still nullable (installation/abuse-control association only, per the same pattern). `object_key`/`content_type`/`byte_size` are what `service.ObjectStore` (a provider-neutral s3-compatible boundary — see [[backend]]) and server-side media validation (decode/re-encode as jpeg/png, size cap) need; `url` is what a client reads, produced by whichever provider `Put` wrote to (a local static-serve route for the `fake` dev provider, a real s3-compatible url for a future production provider). `idempotency_key` plus the partial `media_user_idempotency_uq` index is the same idempotent-retry pattern `follows_user_cat_uq` established (migration 00016): `CreateMedia` inserts `on conflict (uploaded_by_user_id, idempotency_key) where idempotency_key is not null do nothing`, so a retried `POST /v1/media` with the same key never creates a second row.
- `cats.created_by_user_id`/`primary_photo_id`/`idempotency_key` (implemented, migration 00017, issue #70) bring `cats` up to what this doc had already sketched, deferred by migration 00003 until add-cat existed. `created_by_device_id` — sketched above as `not null` — is actually nullable, matching `updates.author_device_id`'s deferral reasoning: seeded cats predate any real device. `photo_url` (issue #7) is not replaced — it stays as the seed-only photo column; `POST /v1/cats` (issue #70) sets `primary_photo_id` instead, referencing the media row its required photo was stored as. `ListCatsInBounds`/`GetCatByID`/`ListFollowedCats` all resolve `coalesce(cats.photo_url, media.url)` via a `left join media on media.id = cats.primary_photo_id`, so a seeded and a created cat both surface the same `primary_photo` field without either read path needing to know which column the value actually came from. `idempotency_key` plus `cats_user_idempotency_uq` is the identical pattern to `media`'s own idempotency column above — `CreateCat` (called inside `Store.CreateCatWithMedia`, which commits the new media row and the new cats row as one transaction) inserts `on conflict (created_by_user_id, idempotency_key) where idempotency_key is not null do nothing`; a conflicting retry rolls the whole transaction back (including the media insert), so `CatsService.Create` resolves it via `GetCatByIdempotencyKey` and deletes the object it had just uploaded to storage rather than leaving an orphan.
- `devices.user_id` (implemented, migration 00012, issue #58): set once phone verification succeeds — `AuthService.VerifyOTP` resolves-or-creates exactly one account per normalized phone number (enforced by `users.phone`'s unique constraint, safe under two concurrent verifications for the same number) and then idempotently sets this column. linking a device already linked to a *different* account is rejected rather than silently reassigning it, so a device's prior authored content is never retroactively re-attributed to a second account; re-verifying the same phone on the same already-linked device is a no-op on the link itself.
  as of migration 00016 (issue #65), `AuthService.linkDevice` also backfills the device's pre-existing `follows.user_id` and `updates.author_user_id` onto the linked account, in the same transaction, immediately after (or in place of, on the no-op path) the link itself — `update follows set user_id = $account where device_id = $device and user_id is null`, and the equivalent for `updates`. both queries only touch rows still missing the account column, so calling them again (a retried transaction, or re-verifying an already-linked device) is a safe no-op rather than a re-assignment, and neither ever runs on the rejected-other-account path. this is what makes "existing device-owned follows/updates remain associated after linking" true without a one-off data migration for every device linked after this shipped (the migration itself does the equivalent one-time backfill for devices already linked before it shipped).
- `updates.updated_at`/`deleted_at` (implemented, migration 00020, issue #80): back the caller's own 10-minute correction/delete window (docs/product/updates.md). Soft delete, not hard delete: `notification_outbox.update_id` (migration 00008) and `notifications.update_id` (migration 00019) both reference `updates(id)` with no `on delete cascade`, so a hard `delete from updates` on any row that ever enqueued outbox/notification work would violate those foreign keys, or (if cascaded) destroy the delivery-audit trail this doc's own notification_outbox design note describes as the at-most-once guarantee's bookkeeping. Soft delete also reconciles two decisions in [[updates]] that read as contradictory but aren't: "ordinary updates never expire or disappear from history" describes what *other readers* see once the correction window has closed, while "users may correct or remove their own update" is the explicit action available *during* the window, to the author's own mistake — a tombstoned row satisfies both: to every reader other than a `deleted_at is null` filter (i.e. everyone, author included — `ListCatUpdates`/`GetUpdateForCorrectionCheck` never distinguish "my own deleted row" from anyone else's), it simply vanishes and can never reappear, while the row itself survives for the concurrency-safety and audit-preservation guarantees `CorrectOrdinaryUpdate`/`DeleteOwnUpdate` (below) need to check against. `CorrectOrdinaryUpdate`'s own `set` clause never touches `author_user_id`/`author_device_id`/`created_at` — a correction can change `comment`/`update_statuses` and stamp `updated_at`, nothing else.
- `CorrectOrdinaryUpdate`/`DeleteOwnUpdate`/`GetUpdateForCorrectionCheck` (implemented, migration 00020/queries, issue #80): the entire authorization + concurrency + expiry check for a correction or delete is one conditional `update ... where id = $1 and cat_id = $2 and author_user_id = $3 and kind = 'ordinary' and deleted_at is null and created_at > $window_start` statement — not a separate read-then-write. `window_start` (`s.clock().Add(-10 * time.Minute)`, see [[backend]]) is always computed by the service against its own injected clock, never a client timestamp or this query's own `now()`. A request that fails any one of those conditions (wrong author, wrong cat, needs-help kind, already deleted, or an expired window) affects zero rows, indistinguishably from any other — `GetUpdateForCorrectionCheck` is the disambiguation step the service calls only on that zero-rows outcome, to decide 403 vs. 404 vs. 410 vs. "already deleted, treat as an idempotent success" (see [[api]]'s error taxonomy). This mirrors the same "one atomic conditional statement, not application-level check-then-write" shape `follows_user_cat_uq`'s `on conflict do nothing` and `notification_outbox.update_id`'s unique constraint already use elsewhere in this schema to make a race condition structurally impossible rather than merely unlikely.
- badges (issue #80, docs/product/badges.md) have **no dedicated table** — `ListUserOrdinaryUpdatesForBadges`/`ListUserNeedsHelpUpdatesForBadges`/`ListUserCreatedCatsForBadges` (new queries, migration-adjacent) feed a pure, deterministic derivation in `service.badgeProgress` (see [[backend]]) computed fresh on every `GET /v1/me/profile`/`GET /v1/me/badges` request, mirroring the approved prototype's own client-side `badgeProgress()`. The issue's own "avoid storing redundant badge counters unless the architecture requires a derived cache with a rebuild/recovery path" guidance is satisfied by not needing one at mvp scale (5 fixed thresholds, a bounded per-account row count) — the same reasoning this doc already applied when dropping the denormalized `cats.needs_help_until` above. **Known, accepted mvp limitation:** because badges are derived at read time rather than cached, deleting (within its own 10-minute window) the exact ordinary update that crossed a badge's threshold can make that badge appear transiently un-earned again on next view — in tension with badges.md's "permanent once earned." Given the narrowness of the window this requires (the one qualifying contribution, deleted within 10 minutes of being posted), this is accepted rather than adding a `user_badges` earned-pin table for this slice; if it needs fixing later, the fix is a minimal insert-only, never-deleted `user_badges(user_id, badge_id, earned_at)` table populated the first time a threshold is crossed.

## open questions

- cat-inactivity threshold.
- duplicate-cat merge mechanism and whether it needs a `merged_into` column or something richer.
- two update-content invariants from issue #3 still aren't enforced at the database level: an ordinary update must carry at least one `update_statuses` row, and a needs-help update must carry none. for the ordinary side, issue #36's `POST /v1/cats/{cat_id}/updates` write path now enforces the "at least one status" half at the application layer — the service rejects an empty/unknown/duplicate status set with `400` before ever opening the transaction, and `Store.CreateOrdinaryUpdate` writes the update row and its statuses (plus `cats.last_update_at`) together as one transaction, so a partial write can't land even though there's no db-level constraint tying the two tables together. the needs-help half (a needs-help update must carry no statuses) remains genuinely unenforced anywhere, since issue #23/#4's own write path still doesn't exist.

## out of scope

- read replicas / sharding — not warranted at mvp scale.
- audit logging / soft-delete history beyond `cats.status` and `updates.deleted_at` (issue #80's narrow correction-window tombstone).
