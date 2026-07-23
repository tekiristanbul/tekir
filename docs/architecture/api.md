# api

## goal

define the http api surface for the tekir mvp backend, matching the product decisions in `docs/product/*.md` and the schema in [[db]].

## decisions

### identity / auth model

two-tier, matching [[trust]] and the mvp scoping conversation: following a cat and posting a text-only update need no login; login (phone otp) is required only when adding a photo/video (including new-cat creation, since a photo is mandatory there).

a client-generated identifier is not sufficient authorization on its own — anything the client can choose or copy, another client can replay to impersonate it for follow/update/notification actions. so the anonymous identity is **server-issued**, not client-asserted. and it needs its own header: `Authorization` is a single-value credential slot in practice (clients and intermediaries generally don't expect two schemes stacked in it), so overloading it with both `Device` and `Bearer` at once is an ambiguous contract. the device credential gets a dedicated header instead:

- **device token**: `POST /v1/devices` takes only `{ push_token, platform }` — the client supplies no id. the server generates `device_id` (a non-secret identifier) and a `device_token` (an opaque, high-entropy secret, stored server-side only as a hash — see [[db]]). every subsequent request sends it as `X-Device-Token: <device_token>`. a token can be revoked server-side (moderation/abuse case, per [[trust]]) without the client being able to forge a replacement — but revocation invalidates *that credential*, not a person or a physical device: a revoked client is free to call `POST /v1/devices` again and get a new identity. this is a mitigation for a single bad session, not a ban mechanism; anything stronger is out of scope for now.
- **account** (phone-verified), obtained via otp. the resulting `access_token` (jwt, short-lived) is sent as `Authorization: Bearer`, which is now unambiguous since `X-Device-Token` carries the device credential separately. verifying links the device's existing follows/updates to the account automatically (same `device_id` server-side, no separate merge call needed). `refresh_token` (opaque, long-lived, stored hashed — see [[db]]) exchanges for a new `access_token` without re-sending an otp.

```
POST /v1/devices                        { push_token, platform }                → { device_id, device_token }
PUT  /v1/devices/me       (X-Device-Token) { push_token }                        → 204   (fcm token refresh)
POST /v1/auth/otp/request               { phone }                                → 202
POST /v1/auth/otp/verify  (X-Device-Token) { phone, code }                       → { access_token, refresh_token, user_id }
POST /v1/auth/refresh                   { refresh_token }                       → { access_token, refresh_token }
GET  /v1/me               (X-Device-Token, optional Bearer)                     → { device_id, user_id|null, phone_verified }
```

### cats

```
GET  /v1/cats?bbox=...                                    → [{ id, name, primary_photo, area{lat,lng}, area_label|null, needs_help, last_update_at }]
GET  /v1/cats/nearby?lat&lng&radius=50                     → [{ id, primary_photo, name }]   (duplicate check in the add-cat flow — not yet implemented)
GET  /v1/cats/{cat_id}                                     → { id, name, area{lat,lng}, area_label|null, primary_photo|null, traits[{key,label}], created_at, last_update_at|null }
POST /v1/cats            (Bearer required)  { area, photo(multipart), traits[], name?, confirmed_new? }
                                             → 201 { cat }  or  409 { candidates:[...] } (when confirmed_new is absent and nearby matches exist — not yet implemented)
```

`GET /v1/cats/{cat_id}` is implemented (issue #21, read-only map-to-detail slice). it deliberately omits `needs_help` and `followed_by_me` from the earlier sketch above: the issue #4 product decision is final (see [[alerts]]), but active-needs-help rendering itself isn't implemented yet — that's issue #4's own follow-up work, not #21's — and there's no follow/account feature yet. `photos[]` is `primary_photo` (nullable) for now — there's no `media` table yet (see [[db]]), so a cat has exactly one photo column. unknown `cat_id` → `404`; a malformed (non-uuid) `cat_id` → `400`.

`area_label` (both endpoints) is a nullable, human-readable location string (e.g. "Moda Sahili, Kadıköy") — display-only, never parsed back into coordinates. added for the issue #21 prototype-parity correction: the map's marker-preview sheet and the cat-detail screen show it in place of raw lat/lng. there is no runtime reverse-geocoding service; it's set once at cat-creation/seed time (see [[db]]). `GET /v1/cats?bbox=` also now returns `name`, alongside `area_label` — the minimum fields the marker-preview sheet needs, so selecting a marker never triggers a second full-detail fetch.

### traits

```
GET  /v1/traits    → [{ key, label }]
```

the active, selectable trait vocabulary (issue #21 product clarification): a controlled, extensible list — not a client-hardcoded set, not free text, not a closed enum (see [[db]]). retired traits are omitted here but not from a cat's own `traits[]` (existing associations survive retirement). trait selection/editing (assigning a trait to a cat) isn't implemented yet; this endpoint exists so a future add/edit-cat flow has a vocabulary to render a selector from. the initial vocabulary content is a proposal pending product-owner review, not a locked list.

### updates

an update is one or more structured statuses from the fixed mvp vocabulary approved on issue #3 (`seen`, `fed`, `water_provided`) plus an optional free-text comment. `needs_help` as an update subtype remains owned by [[alerts]] (issue #4) and isn't modeled here.

```
GET  /v1/cats/{cat_id}/updates?cursor=&limit=   → { items: [{ id, statuses[], comment|null, created_at }], next_cursor|null }
POST /v1/cats/{cat_id}/updates              { statuses[], comment? }          (not yet implemented — issue #21 is read-only)
POST /v1/media           (Bearer required)  multipart file → { media_id, url }
```

`GET /v1/cats/{cat_id}/updates` is implemented (issue #21). newest first, keyset-paginated on `(created_at, seq)` — `seq` is a monotonic tie-breaker for rows that share a `created_at` (see [[db]]). `cursor` is an opaque token taken verbatim from the previous page's `next_cursor`; omit it for the first page. `limit` defaults to 20 and is capped at 50 — an out-of-range or non-integer `limit`, or an undecodable `cursor`, is a `400`. unknown `cat_id` → `404`. `next_cursor` is `null` once there is no further page — a client never has to guess.

### follows / notifications

```
POST   /v1/cats/{cat_id}/follow      (X-Device-Token is enough)   → 204
DELETE /v1/cats/{cat_id}/follow                                  → 204
GET    /v1/me/follows                                            → [cat...]
GET    /v1/me/notifications?cursor=                               → [{ id, cat_id, update_id, read, created_at }]
POST   /v1/me/notifications/{id}/read                             → 204
```

push delivery is not client-facing. every new update writes a row to `notification_outbox` (see [[db]]); the worker (see [[backend]]) polls that table and fans it out to followers. delivery is **at-most-once**: the `notifications` unique constraint (see [[db]]) guarantees a push is never sent twice for the same device/update pair, but it does not guarantee a push is sent at all — a crash between recording the notification and actually sending it loses that push silently. accepted as a small loss window for mvp, not claimed as crash-safe or exactly-once.

### modeling notes

- `cat.needs_help` is derived: the latest update is `help_request` and hasn't expired. the expiry is a fixed 72 hours per the issue #4 product decision ([[alerts]]); still left as a config value in the implementation rather than a hardcoded number.
- `confirmed_new` on `POST /v1/cats` only carries the "yes, this is a different cat" confirmation — it does not implement the actual duplicate-merge mechanism ([[cats]] leaves that open).
- colony vs. individual cat is not modeled — every cat is an atomic record, no grouping.
- the api never produces a single "official current status" when followers post conflicting updates — clients get the full ordered list and display it themselves, per [[updates]]'s "all updates shown, newest first" decision.

## open questions

- duplicate-cat merge mechanism ([[cats]]).
- the initial trait vocabulary's labels and grouping are pending product-owner review ([[cats]]); the model (controlled, extensible, keyed) is decided, the specific list is not.

## out of scope

- moderator/admin endpoints.
- rate limiting and abuse-prevention design.
- api versioning strategy beyond the `/v1` prefix.
