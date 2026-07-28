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
POST /v1/auth/logout      (Bearer; X-Device-Token optional) { refresh_token }    → 204                                       (implemented — issue #58; device unlink — issue #80 product-owner review)
GET  /v1/me               (X-Device-Token, optional Bearer)                     → 200 { device_id, user_id|null, phone_verified } (implemented — issue #58)
PATCH /v1/me              (Bearer)      { display_name }                        → 204                                       (implemented — issue #58)
```

`is_new_account` on otp/verify tells the client whether to show the approved prototype's new-account minimum-profile (display name) step next — true only the first time an account is created for that phone number, never on a returning login. `PATCH /v1/me` is how the client then sets it: a client only calls this right after `is_new_account: true`; the server doesn't itself enforce "only once" or "only for a new account" (that's a client flow convention, not a data invariant) — `users.display_name` has no uniqueness constraint, matching the prototype where multiple accounts may share a display name.

`POST /v1/auth/logout` wasn't in this doc's earlier sketch — added by issue #58, since the product decisions require logout to revoke the account session (not just have the client discard its tokens). It revokes exactly the presented refresh token; it is idempotent (revoking an already-revoked or unknown token still answers 204) and never touches the device's own identity or its follows.

issue #80's product-owner review found that a device, once linked to an account, could never sign into a *different* account on the same installation — `AuthService.linkDevice` permanently rejects (`409`) any relink to a different account once `devices.user_id` is set, and nothing ever cleared it. The fix: logout now optionally accepts `X-Device-Token` and unlinks the device (`devices.user_id = null`) only when it's currently linked to the account performing the logout — a no-op (never an error) for a missing, invalid, or mismatched device token, and logout still succeeds (204) whether or not the unlink itself runs. `linkDevice`'s own conflict check is unchanged: a device still linked to an account it hasn't logged out of keeps rejecting a different account's login with `409` — this only ever *clears* a link that matches the caller's own logout, never reassigns one. Existing follows/updates already backfilled onto the old account (`BackfillFollowsUserID`/`BackfillUpdatesAuthorUserID`, see [[db]]) are never moved or re-attributed by an unlink — those columns are only ever set once, from `NULL`, so a later relink to a different account can't retroactively claim them.

Otp/verify errors: `400` invalid phone, `401` invalid code (not requested or wrong code — the two collapse to one response so a client can't distinguish "you never asked for a code" from "you guessed wrong"), `410` code expired or already consumed (replay), `429` too many attempts, `409` device already linked to a different account. `401` is also what `RequireDeviceToken` answers for a missing or unrecognized `X-Device-Token` — reached before this endpoint's own code-mismatch check ever runs — and is genuinely a different failure from a wrong/expired code: the locally-cached device credential itself is stale (e.g. it was registered against data that no longer exists), not the otp code. Both share status `401`, but their bodies don't: `{"error":"invalid code"}` vs `{"error":"missing device token"}`/`{"error":"invalid device token"}`. The flutter client switches on this body text (`AuthApi._isDeviceTokenError`) to call `DeviceIdentityService.invalidate()` and register a fresh device on retry, instead of endlessly replaying a dead token as if the user just mistyped the code. Otp/request: `400` invalid phone, `429` resend requested before the per-phone cooldown elapses. Refresh: `401` for an expired, revoked, or unknown refresh token — collapsed the same way as otp/verify, so a client can't distinguish why.

under `OTP_PROVIDER=twilio` (issue #59, see [[backend]]) the same statuses and bodies hold — the provider is never named or hinted at in a response. the only observable differences: `429` on otp/request now reflects twilio verify's own send limits rather than the local cooldown; `410` on otp/verify also covers a code that was never requested (twilio reports expired, consumed, and never-started verifications identically, so the local flow's `401` for "not requested" isn't distinguishable there); and a provider timeout or outage surfaces as the existing generic `500` internal error — the same retryable answer any backend dependency outage (e.g. the database) already produces, deliberately not a new response shape.

Device-to-account linking (otp/verify) resolves-or-creates exactly one account per normalized phone number and sets `devices.user_id` once, idempotently — see [[db]]. Linking a device already linked to a *different* account is rejected (`409`) rather than silently reassigning it, so a device's prior authored content is never retroactively re-attributed to a second account.

### cats

```
GET  /v1/cats?bbox=...                                    → [{ id, name, primary_photo, area{lat,lng}, area_label|null, active_alert|null, last_update_at }]
GET  /v1/cats/nearby?lat&lng&radius=50                     → [{ id, primary_photo, name }]   (implemented — issue #70; the add-cat flow's non-blocking duplicate check)
GET  /v1/cats/discover?lat&lng&filter=nearby|needs_help&cursor=&limit=
                                              → 200 { items: [{ id, name, primary_photo, area_label|null, distance_meters, active_alert|null, last_update_at }], next_cursor|null }
                                              (implemented — issue #82; the keşfet screen's two location-aware surfaces)
GET  /v1/cats/{cat_id}                                     → { id, name, area{lat,lng}, area_label|null, primary_photo|null, created_at, last_update_at|null, active_alert|null }
POST /v1/cats            (Bearer required; X-Device-Token optional; Idempotency-Key optional)  multipart { lat, lng, photo, name?, confirmed_new? }
                                              → 201 { cat }  or  409 { candidates:[...] } (when confirmed_new is absent and nearby matches exist)
                                              (implemented — issue #70)
```

`GET /v1/cats/{cat_id}` is implemented (issue #21, read-only map-to-detail slice). it still omits `followed_by_me` from the earlier sketch above — follow/unfollow/list exist as of issue #44 (see "follows / notifications" below), but folding follow status into this read path was left out of that issue's scope. `photos[]` is `primary_photo` (nullable): a cat still has exactly one profile photo (issue #70 doesn't add a gallery), resolved from either the legacy seed-only `photo_url` column or, for a cat created through `POST /v1/cats`, its required `media` row (see [[db]]). unknown `cat_id` → `404`; a malformed (non-uuid) `cat_id` → `400`.

`GET /v1/cats/nearby` (issue #70) is public — a guest reaches this in the add-cat flow up to the moment the auth gate requires signing in, same as any other public read. `radius` is fixed at 50m server-side; a client-supplied value isn't read.

`GET /v1/cats/discover` (issue #82) serves two of the mvp keşfet screen's three surfaces (docs/product/discovery.md) — every active cat, or only those with a currently active needs-help alert, nearest-first from the caller's own `lat`/`lng`. it is deliberately not `GET /v1/cats?bbox=...` extended with a second query-param mode: bbox is an unpaginated viewport query the map already owns, while this is a paginated, distance-ordered read with its own filter vocabulary — folding both into one handler/response shape would make each harder to reason about for no shared benefit. the third surface, followed cats, is **not** reachable through this endpoint at all — it stays on `GET /v1/me/follows` below, private account-owned state, never a public location-aware read. public: like the bbox mode and `GET /v1/cats/nearby`, a guest reaches this with no bearer at all — discovery.md's "nearby" and "needs help" surfaces carry no account-gating requirement, only "followed" does.

`filter` is required and exactly one of `nearby` (no further predicate — every active cat) or `needs_help` (only a cat whose latest needs-help update is still active, decided against the server's own clock, exactly like `active_alert` everywhere else in this doc — never the database's `now()` at some other instant, and never a client-supplied one); any other value is `400`. `lat`/`lng` are required and validated the same way `POST /v1/cats`' area is — well-formed, and within the product's existing istanbul boundary (`istanbulBounds`, see that endpoint's own paragraph above) — `400` outside it. this is the caller's own approximate location, not a cat's; a user physically outside istanbul (or denying location and falling back to some other coordinate) still gets a coherently-ordered, just very one-sided, result rather than an error, as long as that coordinate itself happens to fall inside the boundary — a client is expected to resolve its own device location before calling this, never to guess or hardcode one outside the product's supported area.

pagination is cursor-based, matching `GET /v1/cats/{cat_id}/updates`'s own convention exactly — `limit` defaults to 20, capped at 50, `cursor` is the opaque `next_cursor` from a previous page or absent for the first one, and `next_cursor` is `null` once the last page has been served. the keyset itself is `(distance_meters, id)` rather than a timestamp, since this list is ordered by a value postgis computes at request time, not a stored column — `id` is an arbitrary but deterministic tie-breaker for the (rare, but real) case of two cats sitting at the exact same distance. distance is always computed and ordered server-side via postgis (`st_distance`/`st_dwithin`'s own geography type, see [[db]]) — a client-computed distance or a client's own notion of "still active" is never trusted for either the ordering or the needs_help filter.

`distance_meters` is this endpoint's one field the map/follows cat-summary shape (`catMarkerResponse`) doesn't otherwise carry; `area`/`area{lat,lng}` is deliberately absent from this response — this is a distance-ordered list, not a viewport, and selecting an entry opens the existing cat-detail flow, which already fetches its own coordinates. every other field (`id`, `name`, `primary_photo`, `area_label`, `active_alert`, `last_update_at`) means exactly what it means on `GET /v1/cats?bbox=...`/`GET /v1/me/follows`.

followed cats' own read path is unaffected by this issue: `GET /v1/me/follows` (see "follows / notifications" below) already answers its account-scoped list in one query with the same lateral-join shape `GET /v1/cats/discover`'s own queries use — issue #82 confirmed no N+1 there and made no changes to it.

`POST /v1/cats` (issue #70) is a multipart request: `lat`/`lng` (the concrete encoding of "area" — two plain form fields, not a nested json object, since multipart fields are flat key/value) and `photo` (the required initial photo) are required; `name` and `confirmed_new` ("true"/absent) are optional. Ownership (`created_by_user_id`, optionally `created_by_device_id`) is always resolved from `Authorization: Bearer`/`X-Device-Token`, never the request body. Location must fall within the product's existing Istanbul boundary — the same one `app/lib/core/geo/istanbul_bounds.dart`'s `istanbulBounds` already uses to constrain the map camera, shared by the main map screen and the add-cat location picker (there was no docs/product or docs/architecture boundary constant before this; reusing that exact definition, rather than inventing a new one, is what this issue's own scope required) — outside it is `400`. The photo is validated server-side (decoded as a genuine jpeg/png regardless of claimed content-type, size-capped, re-encoded — which also strips any exif/metadata, per [[privacy]]) and, together with the new `cats` row, committed in one transaction (see [[db]]'s `Store.CreateCatWithMedia`); a validation/media failure or an unconfirmed duplicate match never creates a cat or a stored object. An optional `Idempotency-Key` header makes a retried request (same key) return the original cat instead of creating a second one — see [[db]]'s `cats_user_idempotency_uq`.

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
GET    /v1/cats/{cat_id}/updates?cursor=&limit=   (optional Bearer)   → { items: [{ id, kind, statuses[], comment|null, created_at,
                                                              needs_help_category|null, needs_help_category_label|null,
                                                              needs_help_expires_at|null, needs_help_active|null,
                                                              author_is_me, correction_expires_at|null }],
                                                     next_cursor|null }
POST   /v1/cats/{cat_id}/updates     (Bearer required; X-Device-Token optional; Idempotency-Key optional)  { statuses[], comment? }
                                                                                → 201 { id, kind, statuses[], comment|null, created_at,
                                                                                        author_is_me, correction_expires_at }   (Idempotency-Key — issue #80 product-owner review)
POST   /v1/cats/{cat_id}/needs-help  (Bearer required)  { category, comment? }    → 201 { id, kind, comment|null, created_at,
                                                                                        needs_help_category, needs_help_category_label,
                                                                                        needs_help_expires_at, needs_help_active }  (implemented — issue #78)
PATCH  /v1/cats/{cat_id}/updates/{update_id}  (Bearer required)  { statuses[], comment? }  → 200 { id, kind, statuses[], comment|null,
                                                                                                    created_at, updated_at, author_is_me,
                                                                                                    correction_expires_at }   (implemented — issue #80)
DELETE /v1/cats/{cat_id}/updates/{update_id}  (Bearer required)                             → 204   (implemented — issue #80)
POST /v1/media                      (Bearer required; X-Device-Token optional; Idempotency-Key optional)  multipart file → 201 { media_id, url }  (implemented — issue #70)
GET  /v1/media/objects/{key}                                                    → the object's raw bytes  (implemented — issue #70)
```

`GET /v1/cats/{cat_id}/updates` is implemented (issue #21, extended in #23), newest first and keyset-paginated on `(created_at, seq)`. `OptionalBearer` (issue #80) resolves the caller's own account when a valid bearer is presented, without requiring one — a guest read is unaffected. `author_is_me` is `true` only when the caller's own account id matches the entry's author; `correction_expires_at` is non-null only when `author_is_me && kind == 'ordinary'` (`created_at + 10m`, docs/product/updates.md's fixed window) and is present purely so the client can show the correction affordance/countdown without guessing ownership — the server remains the sole authority on whether an actual correction succeeds. A soft-deleted update (see below) is excluded from this list entirely, for every reader including its own author.

`POST /v1/cats/{cat_id}/updates` resolves the authenticated account from `Authorization: Bearer` (implemented — issue #65, superseding #36's earlier device-token-only contract); `X-Device-Token` may still be supplied and is recorded alongside the account for installation/abuse-control association, but is never sufficient authorization on its own. `statuses` remains a non-empty set from `seen`, `fed`, and `water_provided`; comment-only requests remain invalid. the server derives author (account and, optionally, device) and timestamps and writes the update, statuses, `last_update_at`, and notification outbox entry transactionally. `author_is_me` is always `true` and `correction_expires_at` always `created_at + 10m` on this response (issue #80) — the caller always authored what they just created, and it's always freshly inside its own correction window — so the client can show the correction affordance immediately, without waiting for a reload.

`POST /v1/cats/{cat_id}/needs-help` (implemented — issue #78) also requires bearer authentication; `X-Device-Token` is optional installation/abuse-control association only, identical to the ordinary-update contract above. `category` must be one of the fixed 5-value vocabulary; `expires_at` is server-computed as `created_at + 72h` (never client-supplied). The write and its `notification_outbox` enqueue commit transactionally, exactly like an ordinary update — see [[db]]/[[backend]] for how that outbox row is later drained.

`PATCH`/`DELETE /v1/cats/{cat_id}/updates/{update_id}` (implemented — issue #80) let the author correct or soft-delete their own ordinary update within the fixed 10-minute window (docs/product/updates.md). Authorization (author match), the window check, and concurrency safety are all enforced in a single conditional sql update statement (see [[db]]) rather than separate read-then-write checks, so a stale or duplicate retry can't race past expiry or overwrite newer state. `kind`, author identity, and `created_at` are never alterable through either path — `PATCH` only ever changes `statuses`/`comment` (`updated_at` is server-derived); `DELETE` only ever sets `deleted_at`, never removing the row (see [[db]]). A needs-help update is never a correctable resource through this path at all (its own fixed 72h lifecycle has no manual resolve) — attempting either verb against one answers `404`, identically to an update id that doesn't exist under this `cat_id`. Error taxonomy: `400` malformed body/invalid statuses, `401` missing/invalid bearer, `403` the update exists under this cat but isn't the caller's own (not collapsed into `404` — the full history is already public per [[privacy]], so confirming "exists, but isn't yours" leaks nothing a guest couldn't already see), `404` unknown update/needs-help kind, `410` the window has closed (mirrors the existing otp/verify `410` convention). A retry against an already-deleted row answers success (`204`), not an error — the same idempotent-retry convention this api already uses for `POST /v1/auth/logout` and `POST /v1/me/notifications/{id}/read`.

`POST /v1/media` (issue #70) is standalone media upload — independent of cat creation (a cat's own required initial photo is instead embedded directly in `POST /v1/cats`, above). Validation, ownership resolution, and `Idempotency-Key` handling are identical to `POST /v1/cats`'s photo (same shared pipeline, see [[backend]]). Not yet wired to any other write path — `updates.media_id` exists in [[db]] but no update-creation endpoint accepts one yet; this endpoint exists so that future path has somewhere to upload to.

`GET /v1/media/objects/{key}` (issue #70) is the "controlled read delivery" path for the local/dev `fake` object-storage provider (see [[backend]]) — media is public per [[privacy]], so this route needs no auth. It only ever serves what that provider itself wrote; a future real s3-compatible provider would serve reads from its own public/signed urls directly, never proxied through this route.

### follows / notifications

```
POST   /v1/cats/{cat_id}/follow      (Bearer required; X-Device-Token optional)   → 204   (implemented — issue #65, superseding #44's device-only contract)
DELETE /v1/cats/{cat_id}/follow      (Bearer required)                             → 204   (implemented — issue #65)
GET    /v1/me/follows                (Bearer required)                             → [{ id, name, primary_photo, area{lat,lng}, area_label|null, active_alert|null, last_update_at }]   (implemented — issue #65)
GET    /v1/me/notifications?cursor=                               → { items: [{ id, cat_id, update_id, read, created_at }], next_cursor|null }   (implemented — issue #78)
POST   /v1/me/notifications/{id}/read                             → 204   (implemented — issue #78)
```

following is private, account-owned state (matching [[community]]) and does not create public content. an optional `X-Device-Token` on follow is recorded purely for installation/abuse-control association, never authorization — mirroring the updates contract above. both follow and unfollow are idempotent. pre-existing device-owned follows (issue #44) are backfilled onto an account automatically the moment the owning device links to it (see [[db]]'s `devices.user_id` design note) — no follow is ever lost or requires the client to re-follow after signing in.

`GET /v1/me/notifications` resolves the caller's own devices server-side (never another account's, even a former owner of a now-reassigned device) and returns only what was actually delivered to one of them — see [[db]]'s `notifications` table. `POST .../read` is owner-scoped the same way and idempotent (marking an already-read notification read again is a no-op, never an error).

push delivery remains at-most-once for mvp through the notification outbox and notifications uniqueness constraint. issue #78 introduces the provider-neutral `NotificationSender` interface this depends on (see [[backend]]) — only a deterministic fake/dev-test implementation is wired for mvp; a real push vendor is out of scope and the worker fails to start rather than silently falling back to fake if misconfigured.

### profile / badges

```
GET /v1/me/profile   (Bearer required)   → 200 { display_name|null,
                                                  contribution_totals { updates, helps, cats_added, distinct_cats },
                                                  badges: [{ id, name, icon, condition, descr, value, target, earned, earned_at|null }],
                                                  recent_contributions: [{ type, cat_id, cat_name, cat_primary_photo|null,
                                                                            statuses[]?, needs_help_category|null, needs_help_category_label|null,
                                                                            created_at }] }   (implemented — issue #80)
GET /v1/me/badges    (Bearer required)   → 200 { items: [{ id, name, icon, condition, descr, value, target, earned, earned_at|null }] }   (implemented — issue #80)
```

both are own-account-only this mvp slice — there is no `GET /v1/users/{id}/profile` or any other route exposing another account's profile; issue #80's acceptance criteria describes viewing one's own surface, not a public profile-viewing feature. `display_name` is nullable (an account that never completed the new-account display-name step). `badges` is always all 5 fixed mvp badges (docs/product/badges.md), earned or not, in the same fixed order — never a filtered or reordered list; `earned_at` is non-null only when `earned`. `recent_contributions` is a fixed-size (8), newest-first list capped server-side — `statuses`/`needs_help_category`/`needs_help_category_label` mirror `GET .../updates`'s own shape exactly, so the client composes display copy for a recent contribution the same way it already does for the cat-detail timeline, rather than the server pre-composing a label string. everything here is derived server-side from the account's own `updates`/`cats` rows at request time (see [[db]]) — never a client-supplied counter, badge id, or timestamp.

curated profile avatars (mentioned in docs/product/community.md/privacy.md) are explicitly deferred past this slice: no avatar field exists in this response and no avatar-selection endpoint exists — there is no defined curated set (asset list, count, or picker) anywhere in the product/design references to build against yet. a future slice adds this once that set is defined.

### modeling notes

- a cat's active alert is derived from its latest non-expired needs-help update.
- `confirmed_new` does not implement duplicate merging.
- colony vs. individual cat is not modeled.
- conflicting updates remain visible as ordered history; the api does not produce an authoritative single status.
- `Idempotency-Key` (issue #70, `POST /v1/cats` and `POST /v1/media`; extended to `POST /v1/cats/{cat_id}/updates` by issue #80's product-owner review) is a plain client-generated opaque string, scoped to the authenticated account — retrying the same request with the same key returns the original result rather than creating a duplicate; a different key (or none) is always a new attempt. this is additive to the contract these endpoints already needed for "retries must not create duplicates", not a general api-wide convention yet. for `POST .../updates` specifically, this is the network-level backstop against a rapid repeat "seen" tap — the client's own button state (docs/architecture/flutter.md) is the primary ux guard, this is what makes a genuine double-send safe regardless.

## open questions

- duplicate-cat merge mechanism ([[cats]]).

## out of scope

- moderator/admin endpoints.
- rate limiting and abuse-prevention design.
- api versioning strategy beyond the `/v1` prefix.
