# api

## goal

define the http api surface for the tekir mvp backend, matching the product decisions in `docs/product/*.md` and the schema in [[db]].

## decisions

### identity / auth model

two-tier, matching [[trust]]: public read access requires no account login; following a cat and every user contribution require a phone-verified account. following, ordinary updates, needs-help updates, media uploads, and new-cat creation therefore require `Authorization: Bearer` (issue #65 moved following and ordinary updates onto this model; the rest were bearer-required from the start).

a client-generated identifier is not sufficient identity on its own — anything the client can choose or copy can be replayed. the device credential remains server-issued and gets its own header so device association and bearer authorization stay separate:

- **device token**: `POST /v1/devices` takes only `{ push_token?, platform }` — the client supplies no id. the server generates `device_id` and a high-entropy `device_token`, storing only its sha-256 hash. subsequent device-scoped requests send `X-Device-Token: <device_token>`. the token identifies an app installation for follows, push delivery, and account linking; it does not authorize contribution writes.
- **account** (phone-verified), obtained via otp. the resulting short-lived jwt is sent as `Authorization: Bearer`. verifying links the current device to the account. the opaque refresh token exchanges for new access tokens without repeating otp verification.

```
POST /v1/devices                        { push_token?, platform }               → 201 { device_id, device_token }  (implemented — issue #32)
PUT  /v1/devices/me       (X-Device-Token) { push_token }                        → 204   (not yet — issue #32 scope)
POST /v1/auth/otp/request               { phone }                                → 202                                       (implemented — issue #58)
POST /v1/auth/otp/verify  (X-Device-Token) { phone, code }                       → 200 { access_token, refresh_token, user_id, is_new_account } (implemented — issue #58)
POST /v1/auth/refresh                   { refresh_token }                       → 200 { access_token, refresh_token }        (implemented — issue #58)
POST /v1/auth/logout      (Bearer)      { refresh_token }                       → 204                                       (implemented — issue #58)
GET  /v1/me               (X-Device-Token, optional Bearer)                     → 200 { device_id, user_id|null, phone_verified } (implemented — issue #58)
PATCH /v1/me              (Bearer)      { display_name }                        → 204                                       (implemented — issue #58)
```

`is_new_account` on otp/verify tells the client whether to show the approved prototype's new-account minimum-profile (display name) step next — true only the first time an account is created for that phone number, never on a returning login. `PATCH /v1/me` is how the client then sets it: a client only calls this right after `is_new_account: true`; the server doesn't itself enforce "only once" or "only for a new account" (that's a client flow convention, not a data invariant) — `users.display_name` has no uniqueness constraint, matching the prototype where multiple accounts may share a display name.

`POST /v1/auth/logout` wasn't in this doc's earlier sketch — added by issue #58, since the product decisions require logout to revoke the account session (not just have the client discard its tokens). It revokes exactly the presented refresh token; it is idempotent (revoking an already-revoked or unknown token still answers 204) and never touches the device's own identity or its follows.

Otp/verify errors: `400` invalid phone, `401` invalid code (not requested or wrong code — the two collapse to one response so a client can't distinguish "you never asked for a code" from "you guessed wrong"), `410` code expired or already consumed (replay), `429` too many attempts, `409` device already linked to a different account. Otp/request: `400` invalid phone, `429` resend requested before the per-phone cooldown elapses. Refresh: `401` for an expired, revoked, or unknown refresh token — collapsed the same way as otp/verify, so a client can't distinguish why.

Device-to-account linking (otp/verify) resolves-or-creates exactly one account per normalized phone number and sets `devices.user_id` once, idempotently — see [[db]]. Linking a device already linked to a *different* account is rejected (`409`) rather than silently reassigning it, so a device's prior authored content is never retroactively re-attributed to a second account.

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

`category` is one of the fixed mvp vocabulary (`injured_or_sick`, `food_needed`, `water_needed`, `unsafe_location`, `trapped`); `category_label` is its turkish display label. never a bare boolean — a client needs the category and lifecycle to render an alert meaningfully, not just "something's wrong". the object's mere presence already means "active": the server derives that by comparing `expires_at` against its own clock at request time (see [[db]]), so a client is never asked to make that comparison itself.

`area_label` is a nullable, human-readable display-only location string set at cat creation or seed time. coordinates remain the source of truth.

### traits (dormant legacy storage)

issue #42 removed permanent cat traits from the mvp surface. behavioral observations such as playful, shy, or friendly belong in update comments ([[updates]]), not permanent profile attributes.

### updates

an update is either an ordinary structured-status update or a needs-help update. both are authenticated contributions.

```
GET  /v1/cats/{cat_id}/updates?cursor=&limit=   → { items: [{ id, kind, statuses[], comment|null, created_at,
                                                              needs_help_category|null, needs_help_category_label|null,
                                                              needs_help_expires_at|null, needs_help_active|null }],
                                                     next_cursor|null }
POST /v1/cats/{cat_id}/updates     (Bearer required)  { statuses[], comment? }  → 201 { id, kind, statuses[], comment|null, created_at }
POST /v1/cats/{cat_id}/needs-help  (Bearer required)  { category }              (not yet implemented)
POST /v1/media                      (Bearer required)  multipart file → { media_id, url }
```

`GET /v1/cats/{cat_id}/updates` is implemented (issue #21, extended in #23), newest first and keyset-paginated on `(created_at, seq)`.

`POST /v1/cats/{cat_id}/updates` resolves the authenticated account from `Authorization: Bearer` (implemented — issue #65, superseding #36's earlier device-token-only contract); `X-Device-Token` may still be supplied and is recorded alongside the account for installation/abuse-control association, but is never sufficient authorization on its own. `statuses` remains a non-empty set from `seen`, `fed`, and `water_provided`; comment-only requests remain invalid. the server derives author (account and, optionally, device) and timestamps and writes the update, statuses, `last_update_at`, and notification outbox entry transactionally.

`POST /v1/cats/{cat_id}/needs-help` also requires bearer authentication. `expires_at` is server-computed as `created_at + 72h`.

### follows / notifications

```
POST   /v1/cats/{cat_id}/follow      (Bearer required; X-Device-Token optional)   → 204   (implemented — issue #65, superseding #44's device-only contract)
DELETE /v1/cats/{cat_id}/follow      (Bearer required)                             → 204   (implemented — issue #65)
GET    /v1/me/follows                (Bearer required)                             → [{ id, name, primary_photo, area{lat,lng}, area_label|null, active_alert|null, last_update_at }]   (implemented — issue #65)
GET    /v1/me/notifications?cursor=                               → [{ id, cat_id, update_id, read, created_at }]
POST   /v1/me/notifications/{id}/read                             → 204
```

following is private, account-owned state (matching [[community]]) and does not create public content. an optional `X-Device-Token` on follow is recorded purely for installation/abuse-control association, never authorization — mirroring the updates contract above. both follow and unfollow are idempotent. pre-existing device-owned follows (issue #44) are backfilled onto an account automatically the moment the owning device links to it (see [[db]]'s `devices.user_id` design note) — no follow is ever lost or requires the client to re-follow after signing in.

push delivery remains at-most-once for mvp through the notification outbox and notifications uniqueness constraint.

### modeling notes

- a cat's active alert is derived from its latest non-expired needs-help update.
- `confirmed_new` does not implement duplicate merging.
- colony vs. individual cat is not modeled.
- conflicting updates remain visible as ordered history; the api does not produce an authoritative single status.

## open questions

- duplicate-cat merge mechanism ([[cats]]).

## out of scope

- moderator/admin endpoints.
- rate limiting and abuse-prevention design.
- api versioning strategy beyond the `/v1` prefix.
