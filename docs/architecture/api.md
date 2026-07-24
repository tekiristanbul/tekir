# api

## goal

define the http api surface for the tekir mvp backend, matching the product decisions in `docs/product/*.md` and the schema in [[db]].

## decisions

### identity / auth model

two-tier, matching [[trust]] and the mvp scoping conversation: following a cat and posting a text-only update need no login; login (phone otp) is required only when adding a photo/video (including new-cat creation, since a photo is mandatory there).

a client-generated identifier is not sufficient authorization on its own — anything the client can choose or copy, another client can replay to impersonate it for follow/update/notification actions. so the anonymous identity is **server-issued**, not client-asserted. and it needs its own header: `Authorization` is a single-value credential slot in practice (clients and intermediaries generally don't expect two schemes stacked in it), so overloading it with both `Device` and `Bearer` at once is an ambiguous contract. the device credential gets a dedicated header instead:

- **device token**: `POST /v1/devices` takes only `{ push_token?, platform }` — the client supplies no id. the server generates `device_id` (a non-secret identifier) and a `device_token` (an opaque, high-entropy secret — 32 bytes of secure random, base64url-encoded — stored server-side only as a sha-256 hash; see [[db]]). the response includes `Cache-Control: no-store` and is the only time the raw token is available. every subsequent request sends it as `X-Device-Token: <device_token>`. a token can be revoked server-side (moderation/abuse case, per [[trust]]) without the client being able to forge a replacement — but revocation invalidates *that credential*, not a person or a physical device: a revoked client is free to call `POST /v1/devices` again and get a new identity. this is a mitigation for a single bad session, not a ban mechanism; anything stronger is out of scope for now. `push_token` is optional; `PUT /v1/devices/me` (push-token refresh) is not yet implemented.
- **account** (phone-verified), obtained via otp. the resulting `access_token` (jwt, short-lived) is sent as `Authorization: Bearer`, which is now unambiguous since `X-Device-Token` carries the device credential separately. verifying links the device's existing follows/updates to the account automatically (same `device_id` server-side, no separate merge call needed). `refresh_token` (opaque, long-lived, stored hashed — see [[db]]) exchanges for a new `access_token` without re-sending an otp.

```
POST /v1/devices                        { push_token?, platform }               → 201 { device_id, device_token }  (implemented — issue #32)
PUT  /v1/devices/me       (X-Device-Token) { push_token }                        → 204   (not yet — issue #32 scope)
POST /v1/auth/otp/request               { phone }                                → 202
POST /v1/auth/otp/verify  (X-Device-Token) { phone, code }                       → { access_token, refresh_token, user_id }
POST /v1/auth/refresh                   { refresh_token }                       → { access_token, refresh_token }
GET  /v1/me               (X-Device-Token, optional Bearer)                     → { device_id, user_id|null, phone_verified }
```

### cats

```
GET  /v1/cats?bbox=...                                    → [{ id, name, primary_photo, area{lat,lng}, area_label|null, active_alert|null, last_update_at }]
GET  /v1/cats/nearby?lat&lng&radius=50                     → [{ id, primary_photo, name }]   (duplicate check in the add-cat flow — not yet implemented)
GET  /v1/cats/{cat_id}                                     → { id, name, area{lat,lng}, area_label|null, primary_photo|null, created_at, last_update_at|null, active_alert|null }
POST /v1/cats            (Bearer required)  { area, photo(multipart), name?, confirmed_new? }
                                             → 201 { cat }  or  409 { candidates:[...] } (when confirmed_new is absent and nearby matches exist — not yet implemented)
```

`GET /v1/cats/{cat_id}` is implemented (issue #21, read-only map-to-detail slice). it still omits `followed_by_me` from the earlier sketch above — follow/unfollow/list exist as of issue #44 (see "follows / notifications" below), but folding follow status into this read path was left out of that issue's scope. `photos[]` is `primary_photo` (nullable) for now — there's no `media` table yet (see [[db]]), so a cat has exactly one photo column. unknown `cat_id` → `404`; a malformed (non-uuid) `cat_id` → `400`.

`active_alert` (both endpoints, issue #4/#23) is `null` unless the cat has a currently-active needs-help alert:

```
active_alert: { category, category_label, created_at, expires_at } | null
```

`category` is one of the fixed mvp vocabulary (`injured_or_sick`, `food_needed`, `water_needed`, `unsafe_location`, `trapped`); `category_label` is its turkish display label. never a bare boolean — a client needs the category and lifecycle to render an alert meaningfully, not just "something's wrong". the object's mere presence already means "active": the server derives that by comparing `expires_at` against its own clock at request time (see [[db]]), so a client is never asked to make that comparison itself, and can't get it wrong by trusting its own clock.

`area_label` (both endpoints) is a nullable, human-readable location string (e.g. "Moda Sahili, Kadıköy") — display-only, never parsed back into coordinates. added for the issue #21 prototype-parity correction: the map's marker-preview sheet and the cat-detail screen show it in place of raw lat/lng. there is no runtime reverse-geocoding service; it's set once at cat-creation/seed time (see [[db]]). `GET /v1/cats?bbox=` also now returns `name`, alongside `area_label` — the minimum fields the marker-preview sheet needs, so selecting a marker never triggers a second full-detail fetch.

### traits (dormant legacy storage)

issue #42 removed permanent cat traits from the mvp surface: `GET /v1/traits` no longer exists, and `GET /v1/cats/{cat_id}` no longer returns a `traits` field. the underlying `traits`/`trait_groups`/`cat_traits` tables and their existing rows are untouched (see [[db]]) — dormant storage that current api responses never read from or write to. behavioral observations such as playful, shy, or friendly now belong in update comments ([[updates]]), not a permanent cat-profile attribute.

### updates

an update is either an ordinary status update — one or more structured statuses from the fixed mvp vocabulary approved on issue #3 (`seen`, `fed`, `water_provided`) plus an optional free-text comment — or a needs-help update (issue #4/#23), an explicit subtype of the same history sharing the same table, carrying a fixed category and its own lifecycle instead of statuses. `kind` (`"ordinary"` | `"needs_help"`) discriminates the two.

```
GET  /v1/cats/{cat_id}/updates?cursor=&limit=   → { items: [{ id, kind, statuses[], comment|null, created_at,
                                                              needs_help_category|null, needs_help_category_label|null,
                                                              needs_help_expires_at|null, needs_help_active|null }],
                                                     next_cursor|null }
POST /v1/cats/{cat_id}/updates  (X-Device-Token required)  { statuses[], comment? }  → 201 { id, kind, statuses[], comment|null, created_at }
POST /v1/cats/{cat_id}/needs-help  (Bearer required)  { category }            (not yet implemented — see below)
POST /v1/media           (Bearer required)  multipart file → { media_id, url }
```

`GET /v1/cats/{cat_id}/updates` is implemented (issue #21, extended in #23). newest first, keyset-paginated on `(created_at, seq)` — `seq` is a monotonic tie-breaker for rows that share a `created_at` (see [[db]]). `cursor` is an opaque token taken verbatim from the previous page's `next_cursor`; omit it for the first page. `limit` defaults to 20 and is capped at 50 — an out-of-range or non-integer `limit`, or an undecodable `cursor`, is a `400`. unknown `cat_id` → `404`. `next_cursor` is `null` once there is no further page — a client never has to guess. an entry's `needs_help_*` fields are populated only when `kind` is `"needs_help"`; `needs_help_active` is decided by the server against its own clock (never the client's), so an entry never asks the client to compare timestamps itself — and an expired entry stays in the list exactly like an ordinary one, just with `needs_help_active: false`, per [[alerts]]'s "72 hours removes emphasis, not the record" decision.

`POST /v1/cats/{cat_id}/updates` is implemented (issue #36): a client with a valid server-issued device token (`X-Device-Token`, resolved the same way as [[trust]]'s other device-token routes — no `Bearer`) records an ordinary status update. `statuses` is a non-empty set drawn from the fixed vocabulary, no duplicates — an empty set, an unlisted value, or a repeated value is a `400`, and a comment-only body (no `statuses`) is rejected the same way. `comment` is optional and never sufficient on its own. any field outside `{statuses, comment}` — `kind`, `media`, a needs-help field, `created_at`, `seq`, an author identity — is rejected as an unknown field, never silently ignored: `kind` is always `"ordinary"` here, and `created_at`/`author_device_id` are always server-derived from the resolved device identity, never accepted from the caller. unknown `cat_id` → `404`; an invalid or unresolvable device token → the same `401` as the other device-token routes. the update row, its statuses, the cat's `last_update_at` (moved forward monotonically — an out-of-order commit of an older update can never move it backwards), and an explicit `notification_outbox` enqueue (see [[db]]; issue #38 replaced the earlier table-wide insert trigger with this in-transaction call so only this write path ever produces outbox work) all commit as one transaction, for the not-yet-implemented delivery worker.

`POST /v1/cats/{cat_id}/needs-help` isn't implemented yet — issue #23 is a read-path slice, matching #21's own scoping. documented here so its authentication requirement is settled ahead of the write path actually landing: creating a needs-help alert always requires `Bearer` (phone-verified account), per the issue #4 product decision (see [[trust]]) — unlike an ordinary update or a follow, which only need a device token. the request accepts `category` only; `expires_at` is always server-computed as `created_at + 72h` (see [[db]]) and a client-supplied expiry is rejected, not merely ignored.

### follows / notifications

```
POST   /v1/cats/{cat_id}/follow      (X-Device-Token required)   → 204   (implemented — issue #44)
DELETE /v1/cats/{cat_id}/follow      (X-Device-Token required)   → 204   (implemented — issue #44)
GET    /v1/me/follows                (X-Device-Token required)   → [{ id, name, primary_photo, area{lat,lng}, area_label|null, active_alert|null, last_update_at }]   (implemented — issue #44)
GET    /v1/me/notifications?cursor=                               → [{ id, cat_id, update_id, read, created_at }]
POST   /v1/me/notifications/{id}/read                             → 204
```

follow/unfollow/list (issue #44) are device-owned like an ordinary update: `X-Device-Token` alone is enough, no `Bearer` required, matching [[trust]]'s "guests can follow a cat" decision. ownership is derived only from the resolved device identity (`DeviceFromContext`, never a client-supplied device id anywhere in the request) — the same convention `POST /v1/cats/{cat_id}/updates` uses for `author_device_id`. both `follow` and `unfollow` are idempotent: following an already-followed cat, or unfollowing a cat this device doesn't follow, still answers `204` rather than an error — `follows`'s `(device_id, cat_id)` primary key with an on-conflict-do-nothing insert makes this safe even under concurrent duplicate requests (see [[db]]). unknown `cat_id` → `404` for both; malformed (non-uuid) `cat_id` → `400`.

`GET /v1/me/follows` returns the resolved device's own followed cats in the exact same cat-summary shape as `GET /v1/cats?bbox=` — no bespoke follows-only representation, and no invented social metrics (follower counts, etc.) beyond what the map/detail views already expose. ordered by most recent cat activity (`last_update_at desc`, nulls last — a followed cat with no updates yet sorts after every cat with real activity), with `id desc` as an explicit tie-breaker for cats sharing the same `last_update_at` (including two never-updated cats). a device only ever sees its own follows; there is no cross-device visibility. the list is a plain array with no pagination — a single device's own follows are bounded by human attention, unlike the public update-history endpoint above. when a device is later linked to an account (`POST /v1/auth/otp/verify`), its `follows` rows are preserved as-is — linking is keyed on the same `device_id`, no merge step needed.

push delivery is not client-facing. every `POST /v1/cats/{cat_id}/updates` write enqueues a row to `notification_outbox` (see [[db]]) explicitly, in the same transaction as the update itself — this is currently the only write path that does, since it's the only implemented update-creation endpoint; the worker (see [[backend]]) polls that table and fans it out to followers. delivery is **at-most-once**: the `notifications` unique constraint (see [[db]]) guarantees a push is never sent twice for the same device/update pair, but it does not guarantee a push is sent at all — a crash between recording the notification and actually sending it loses that push silently. accepted as a small loss window for mvp, not claimed as crash-safe or exactly-once. issue #44 does not touch this path: it neither enqueues notifications nor handles push tokens.

### modeling notes

- a cat's active alert is derived, never a stored boolean: the map/cat-detail read paths look up the cat's latest `needs_help` update and the server decides "active" by comparing its `expires_at` against the current time — expiry is a fixed 72 hours per the issue #4 product decision ([[alerts]]), kept as a named constant in the implementation rather than a hardcoded literal at each call site.
- `confirmed_new` on `POST /v1/cats` only carries the "yes, this is a different cat" confirmation — it does not implement the actual duplicate-merge mechanism ([[cats]] leaves that open).
- colony vs. individual cat is not modeled — every cat is an atomic record, no grouping.
- the api never produces a single "official current status" when followers post conflicting updates — clients get the full ordered list and display it themselves, per [[updates]]'s "all updates shown, newest first" decision.

## open questions

- duplicate-cat merge mechanism ([[cats]]).

## out of scope

- moderator/admin endpoints.
- rate limiting and abuse-prevention design.
- api versioning strategy beyond the `/v1` prefix.
