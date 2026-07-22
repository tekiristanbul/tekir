# api

## goal

define the http api surface for the cats istanbul mvp backend, matching the product decisions in `docs/product/*.md` and the schema in [[db]].

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
GET  /v1/cats?bbox=...                                    → [{ id, primary_photo, area{lat,lng}, needs_help, last_update_at }]
GET  /v1/cats/nearby?lat&lng&radius=50                     → [{ id, primary_photo, name }]   (duplicate check in the add-cat flow)
GET  /v1/cats/{cat_id}                                     → { id, photos[], traits[], name|null, area, needs_help, followed_by_me }
POST /v1/cats            (Bearer required)  { area, photo(multipart), traits[], name?, confirmed_new? }
                                             → 201 { cat }  or  409 { candidates:[...] } (when confirmed_new is absent and nearby matches exist)
```

### updates

> ⚠ **provisional contract.** [[updates]] specifies a *structured* status with an optional comment; no minimum status vocabulary is defined yet (tracked in `docs/backlog.md` as a blocking decision). until it is, `comment` is free text and nothing in the product can reliably query it ("was the cat fed?", "was water provided?") — don't build features that assume it can. this shape is expected to change once the vocabulary is decided; it is not a stable contract yet.

```
GET  /v1/cats/{cat_id}/updates?cursor=      → [{ id, type: status|help_request, comment|null, media_id|null, created_at }]  (newest first)
POST /v1/cats/{cat_id}/updates              { type, comment?, media_id? }
                                             (media_id present → Bearer required; absent → X-Device-Token alone is enough)
POST /v1/media           (Bearer required)  multipart file → { media_id, url }
```

### follows / notifications

```
POST   /v1/cats/{cat_id}/follow      (X-Device-Token is enough)   → 204
DELETE /v1/cats/{cat_id}/follow                                  → 204
GET    /v1/me/follows                                            → [cat...]
GET    /v1/me/notifications?cursor=                               → [{ id, cat_id, update_id, read, created_at }]
POST   /v1/me/notifications/{id}/read                             → 204
```

push delivery is not client-facing. every new update writes a row to `notification_outbox` (see [[db]]); the worker (see [[backend]]) polls that table and fans it out to followers. the fan-out is idempotent under retries/crashes — see the `notifications` unique constraint in [[db]] — so a push is never sent twice for the same device/update pair even if the worker dies mid-batch and re-polls the same outbox row.

### modeling notes

- `cat.needs_help` is derived: the latest update is `help_request` and hasn't expired. the expiry duration is unresolved (see [[alerts]] open question) and is left as a config value, not a hardcoded number.
- `confirmed_new` on `POST /v1/cats` only carries the "yes, this is a different cat" confirmation — it does not implement the actual duplicate-merge mechanism ([[cats]] leaves that open).
- colony vs. individual cat is not modeled — every cat is an atomic record, no grouping.
- the api never produces a single "official current status" when followers post conflicting updates — clients get the full ordered list and display it themselves, per [[updates]]'s "all updates shown, newest first" decision.

## open questions

- `needs_help` expiry duration ([[alerts]]).
- fixed enum/vocabulary for status-update content ([[updates]]).
- duplicate-cat merge mechanism ([[cats]]).
- whether `help_request` notifications should behave differently from regular update notifications ([[notifications]]).

## out of scope

- moderator/admin endpoints.
- rate limiting and abuse-prevention design.
- api versioning strategy beyond the `/v1` prefix.
