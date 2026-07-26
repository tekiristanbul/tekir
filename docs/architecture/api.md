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
GET  /v1/cats/nearby?lat&lng&radius=50                     → [{ id, primary_photo, name }]   (implemented — issue #70; the add-cat flow's non-blocking duplicate check)
GET  /v1/cats/{cat_id}                                     → { id, name, area{lat,lng}, area_label|null, primary_photo|null, created_at, last_update_at|null, active_alert|null }
POST /v1/cats            (Bearer required; X-Device-Token optional; Idempotency-Key optional)  multipart { lat, lng, photo, name?, confirmed_new? }
                                              → 201 { cat }  or  409 { candidates:[...] } (when confirmed_new is absent and nearby matches exist)
                                              (implemented — issue #70)
```

`GET /v1/cats/{cat_id}` is implemented (issue #21, read-only map-to-detail slice). it still omits `followed_by_me` from the earlier sketch above — follow/unfollow/list exist as of issue #44 (see "follows / notifications" below), but folding follow status into this read path was left out of that issue's scope. `photos[]` is `primary_photo` (nullable): a cat still has exactly one profile photo (issue #70 doesn't add a gallery), resolved from either the legacy seed-only `photo_url` column or, for a cat created through `POST /v1/cats`, its required `media` row (see [[db]]). unknown `cat_id` → `404`; a malformed (non-uuid) `cat_id` → `400`.

`GET /v1/cats/nearby` (issue #70) is public — a guest reaches this in the add-cat flow up to the moment the auth gate requires signing in, same as any other public read. `radius` is fixed at 50m server-side; a client-supplied value isn't read.

`POST /v1/cats` (issue #70) is a multipart request: `lat`/`lng` (the concrete encoding of "area" — two plain form fields, not a nested json object, since multipart fields are flat key/value) and `photo` (the required initial photo) are required; `name` and `confirmed_new` ("true"/absent) are optional. Ownership (`created_by_user_id`, optionally `created_by_device_id`) is always resolved from `Authorization: Bearer`/`X-Device-Token`, never the request body. Location must fall within the product's existing Istanbul boundary — the same one `app/lib/features/map/ui/map_screen.dart`'s `_istanbulBounds` already uses to constrain the map camera (there was no docs/product or docs/architecture boundary constant before this; reusing that exact definition, rather than inventing a new one, is what this issue's own scope required) — outside it is `400`. The photo is validated server-side (decoded as a genuine jpeg/png regardless of claimed content-type, size-capped, re-encoded — which also strips any exif/metadata, per [[privacy]]) and, together with the new `cats` row, committed in one transaction (see [[db]]'s `Store.CreateCatWithMedia`); a validation/media failure or an unconfirmed duplicate match never creates a cat or a stored object. An optional `Idempotency-Key` header makes a retried request (same key) return the original cat instead of creating a second one — see [[db]]'s `cats_user_idempotency_uq`.

`409 { candidates: [...] }`'s candidates are the same `{ id, primary_photo, name }` shape `GET /v1/cats/nearby` returns — advisory only ([[cats]]/[[trust]]): the client shows them, and a second `POST /v1/cats` with `confirmed_new: true` always proceeds regardless of what's nearby.

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
POST /v1/media                      (Bearer required; X-Device-Token optional; Idempotency-Key optional)  multipart file → 201 { media_id, url }  (implemented — issue #70)
GET  /v1/media/objects/{key}                                                    → the object's raw bytes  (implemented — issue #70)
```

`GET /v1/cats/{cat_id}/updates` is implemented (issue #21, extended in #23), newest first and keyset-paginated on `(created_at, seq)`.

`POST /v1/cats/{cat_id}/updates` resolves the authenticated account from `Authorization: Bearer` (implemented — issue #65, superseding #36's earlier device-token-only contract); `X-Device-Token` may still be supplied and is recorded alongside the account for installation/abuse-control association, but is never sufficient authorization on its own. `statuses` remains a non-empty set from `seen`, `fed`, and `water_provided`; comment-only requests remain invalid. the server derives author (account and, optionally, device) and timestamps and writes the update, statuses, `last_update_at`, and notification outbox entry transactionally.

`POST /v1/cats/{cat_id}/needs-help` also requires bearer authentication. `expires_at` is server-computed as `created_at + 72h`.

`POST /v1/media` (issue #70) is standalone media upload — independent of cat creation (a cat's own required initial photo is instead embedded directly in `POST /v1/cats`, above). Validation, ownership resolution, and `Idempotency-Key` handling are identical to `POST /v1/cats`'s photo (same shared pipeline, see [[backend]]). Not yet wired to any other write path — `updates.media_id` exists in [[db]] but no update-creation endpoint accepts one yet; this endpoint exists so that future path has somewhere to upload to.

`GET /v1/media/objects/{key}` (issue #70) is the "controlled read delivery" path for the local/dev `fake` object-storage provider (see [[backend]]) — media is public per [[privacy]], so this route needs no auth. It only ever serves what that provider itself wrote; a future real s3-compatible provider would serve reads from its own public/signed urls directly, never proxied through this route.

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
- `Idempotency-Key` (issue #70, `POST /v1/cats` and `POST /v1/media`) is a plain client-generated opaque string, scoped to the authenticated account — retrying the same request with the same key returns the original result rather than creating a duplicate; a different key (or none) is always a new attempt. this is additive to the contract these two endpoints already needed for "retries must not create duplicate cats/media", not a general api-wide convention yet.

## open questions

- duplicate-cat merge mechanism ([[cats]]).

## out of scope

- moderator/admin endpoints.
- rate limiting and abuse-prevention design.
- api versioning strategy beyond the `/v1` prefix.
