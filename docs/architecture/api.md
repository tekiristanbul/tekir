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
PUT  /v1/devices/me       (X-Device-Token) { push_token }                        → 204   (implemented — issue #84: registers/refreshes the caller installation's fcm token in place; the same token is cleared off any other device row so a re-registered installation is never pushed twice; the token is never echoed back or logged)
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
GET  /v1/cats/{cat_id}                                     (optional Bearer)   → { id, name, area{lat,lng}, area_label|null, primary_photo|null, created_at, last_update_at|null, active_alert|null, media_count, is_owner }
GET  /v1/cats/{cat_id}/media                                → [{ id, url, is_cover, created_at }]   (implemented — issue #121; the "medya" archive tab; also carries media_content_type and media_muted, issue #194)
PATCH /v1/cats/{cat_id}  (Bearer required)  { name }   → 200 { cat }
                                              (implemented — issue #199)
DELETE /v1/cats/{cat_id}  (Bearer required)              → 204
                                              (implemented — issue #200)
PATCH /v1/cats/{cat_id}/cover  (Bearer required)  { media_id }   → 200 { cat }
                                              (implemented — issue #156)
POST /v1/cats            (Bearer required; X-Device-Token optional; Idempotency-Key optional)  multipart { lat, lng, photo, name?, confirmed_new? }
                                              → 201 { cat }  or  409 { candidates:[...] } (when confirmed_new is absent and nearby matches exist)
                                              (implemented — issue #70)
```

`GET /v1/cats/{cat_id}` is implemented (issue #21, read-only map-to-detail slice). it still omits `followed_by_me` from the earlier sketch above — follow/unfollow/list exist as of issue #44 (see "follows / notifications" below), but folding follow status into this read path was left out of that issue's scope. `photos[]` is `primary_photo` (nullable): a cat still has exactly one *cover* photo (issue #70 doesn't add a gallery to this field; the full archive is `GET /v1/cats/{cat_id}/media`), resolved from either the legacy seed-only `photo_url` column or, for a cat created through `POST /v1/cats`, its required `media` row (see [[db]]). unknown `cat_id` → `404`; a malformed (non-uuid) `cat_id` → `400`. A soft-deleted cat (issue #200) answers the identical `404` — deletion is terminal, so there is no owner-only "still visible to me" exception, even for a caller who is the cat's own creator. `is_owner` (issue #156) is `true` only for the cat's own `created_by_user_id` account's authenticated read — `OptionalBearer` resolves the caller without requiring one, so a guest read is unaffected and always gets `false`; the client uses this, and only this, to decide whether to offer the cover-change affordance in the media archive.

`PATCH /v1/cats/{cat_id}/cover` (issue #156) lets the cat's own owner promote an existing `GET /v1/cats/{cat_id}/media` entry to be the cover: `media_id` must already belong to that cat's own archive, never an arbitrary media row. Only `cats.primary_photo_id` moves — the update or upload the photo originally came from is never modified, so contributed media stays attached to its own update. `403` when the caller isn't the cat's owner (including another authenticated account); `400` for a malformed `media_id` or one that isn't part of this cat's own archive; `404` for an unknown `cat_id`.

`GET /v1/cats/{cat_id}/media` excludes an archive entry whose only owning update (the update it was attached through, via `updates.media_id`) has been soft-deleted (see the `DELETE .../updates/{update_id}` product decision below) — deleting an update removes its media from the archive the same way it already vanished from the timeline. An entry attached through more than one update stays visible as long as any one of them is still live; an entry with no owning update at all (the cat's own required cover photo from `POST /v1/cats`) is never affected by this filter. This is a read-time filter only — `cat_media` rows are never deleted or modified, so nothing here is a hard delete (see [[db]]).

`PATCH /v1/cats/{cat_id}` (issue #199) lets the cat's own owner correct the cat's `name` — the one recovery path for a naming mistake made at `POST /v1/cats` creation time. `name` is trimmed of surrounding whitespace server-side; empty or whitespace-only is `400`. Ownership is derived from `created_by_user_id` against the authenticated caller exactly like `PATCH .../cover` — `403` for anyone else, including another authenticated account, never accepted from the request body. Nothing else about the cat (media, updates, location, ownership, or unrelated timestamps) is touched. `404` for an unknown `cat_id`; `400` for a malformed (non-uuid) `cat_id`.

`DELETE /v1/cats/{cat_id}` (issue #200) lets the cat's own owner soft-delete it — the one recovery path for a cat added by mistake. Ownership is derived from `created_by_user_id` against the authenticated caller exactly like `PATCH .../cover`/`PATCH /v1/cats/{cat_id}` — `403` for anyone else, including another authenticated account. `404` for an unknown `cat_id`; `400` for a malformed (non-uuid) `cat_id`. Deletion sets `cats.status = 'deleted'` (see [[db]]) — a terminal state in this version: there is no restore/reactivate endpoint or behavior, and repeating the request afterward (by the same owner) answers success (`204`), not an error, the same idempotent-retry convention `DELETE .../updates/{update_id}` already established. No cat, media, or update row is ever physically removed, and no dependent data (updates, media, attribution, ownership) is touched — only the cat's own `status` moves. A deleted cat is excluded from every active read surface: `GET /v1/cats?bbox=`, `GET /v1/cats/nearby`, `GET /v1/cats/discover`, `GET /v1/cats/{cat_id}` (`404`, see above), `GET /v1/cats/{cat_id}/media`, and `GET /v1/cats/{cat_id}/updates` all stop serving it, and `POST /v1/cats/{cat_id}/updates`/`POST /v1/cats/{cat_id}/needs-help` stop accepting new contributions to it (`404`) — deletion is terminal, so nothing extends a deleted cat's history further. `PATCH /v1/cats/{cat_id}`/`PATCH .../cover` answer the same `404` for a deleted cat, since both resolve ownership through the same now-filtered read as the detail endpoint.

`GET /v1/cats/nearby` (issue #70) is public — a guest reaches this in the add-cat flow up to the moment the auth gate requires signing in, same as any other public read. `radius` is fixed at 50m server-side; a client-supplied value isn't read.

`GET /v1/cats/discover` (issue #82) serves two of the mvp keşfet screen's three surfaces (docs/product/discovery.md) — every active cat, or only those with a currently active needs-help alert, nearest-first from the caller's own `lat`/`lng`. it is deliberately not `GET /v1/cats?bbox=...` extended with a second query-param mode: bbox is an unpaginated viewport query the map already owns, while this is a paginated, distance-ordered read with its own filter vocabulary — folding both into one handler/response shape would make each harder to reason about for no shared benefit. the third surface, followed cats, is **not** reachable through this endpoint at all — it stays on `GET /v1/me/follows` below, private account-owned state, never a public location-aware read. public: like the bbox mode and `GET /v1/cats/nearby`, a guest reaches this with no bearer at all — discovery.md's "nearby" and "needs help" surfaces carry no account-gating requirement, only "followed" does.

`filter` is required and exactly one of `nearby` (no further predicate — every active cat) or `needs_help` (only a cat whose latest needs-help update is still active, decided against the server's own clock, exactly like `active_alert` everywhere else in this doc — never the database's `now()` at some other instant, and never a client-supplied one); any other value is `400`. `lat`/`lng` are required and validated the same way `POST /v1/cats`' area is — well-formed, and within the product's existing istanbul boundary (`istanbulBounds`, see that endpoint's own paragraph above) — `400` outside it. this is the caller's own approximate location, not a cat's; a user physically outside istanbul (or denying location and falling back to some other coordinate) still gets a coherently-ordered, just very one-sided, result rather than an error, as long as that coordinate itself happens to fall inside the boundary — a client is expected to resolve its own device location before calling this, never to guess or hardcode one outside the product's supported area.

pagination is cursor-based, matching `GET /v1/cats/{cat_id}/updates`'s own convention exactly — `limit` defaults to 20, capped at 50, `cursor` is the opaque `next_cursor` from a previous page or absent for the first one, and `next_cursor` is `null` once the last page has been served. the keyset itself is `(distance_meters, id)` rather than a timestamp, since this list is ordered by a value postgis computes at request time, not a stored column — `id` is an arbitrary but deterministic tie-breaker for the (rare, but real) case of two cats sitting at the exact same distance. distance is always computed and ordered server-side via postgis (`st_distance`/`st_dwithin`'s own geography type, see [[db]]) — a client-computed distance or a client's own notion of "still active" is never trusted for either the ordering or the needs_help filter.

`distance_meters` is this endpoint's one field the map/follows cat-summary shape (`catMarkerResponse`) doesn't otherwise carry; `area`/`area{lat,lng}` is deliberately absent from this response — this is a distance-ordered list, not a viewport, and selecting an entry opens the existing cat-detail flow, which already fetches its own coordinates. every other field (`id`, `name`, `primary_photo`, `area_label`, `active_alert`, `last_update_at`) means exactly what it means on `GET /v1/cats?bbox=...`/`GET /v1/me/follows`.

followed cats' own read path is unaffected by this issue: `GET /v1/me/follows` (see "follows / notifications" below) already answers its account-scoped list in one query with the same lateral-join shape `GET /v1/cats/discover`'s own queries use — issue #82 confirmed no N+1 there and made no changes to it.

`POST /v1/cats` (issue #70) is a multipart request: `lat`/`lng` (the concrete encoding of "area" — two plain form fields, not a nested json object, since multipart fields are flat key/value) and `photo` (the required initial photo) are required; `name` and `confirmed_new` ("true"/absent) are optional. Ownership (`created_by_user_id`, optionally `created_by_device_id`) is always resolved from `Authorization: Bearer`/`X-Device-Token`, never the request body. Location must fall within the product's existing Istanbul boundary — the same one `app/lib/core/geo/istanbul_bounds.dart`'s `istanbulBounds` already uses to constrain the map camera, shared by the main map screen and the add-cat location picker (there was no docs/product or docs/architecture boundary constant before this; reusing that exact definition, rather than inventing a new one, is what this issue's own scope required) — outside it is `400`. The photo is validated server-side (decoded as a genuine jpeg/png regardless of claimed content-type, size-capped, re-encoded — which also strips any exif/metadata, per [[privacy]], after correcting a jpeg's own exif orientation into the pixel data so the stored image is upright regardless of how the camera wrote it — see [[backend]]'s media pipeline) and, together with the new `cats` row, committed in one transaction (see [[db]]'s `Store.CreateCatWithMedia`); a validation/media failure or an unconfirmed duplicate match never creates a cat or a stored object. An optional `Idempotency-Key` header makes a retried request (same key) return the original cat instead of creating a second one — see [[db]]'s `cats_user_idempotency_uq`.

`409 { candidates: [...] }`'s candidates are the same `{ id, primary_photo, name }` shape `GET /v1/cats/nearby` returns — advisory only ([[cats]]/[[trust]]): the client shows them, and a second `POST /v1/cats` with `confirmed_new: true` always proceeds regardless of what's nearby.

`active_alert` (both endpoints, issue #4/#23; reshaped by #101 for the issue #100 simplified help contract) is `null` unless the cat has a currently-active help state:

```
active_alert: { category, category_label, comment|null, created_at, expires_at } | null
```

`comment` is the reporter's optional note — the field 0.2 clients render. `category`/`category_label` are 0.1 compatibility fields (that client generation requires them non-null): a legacy record serves its stored vocabulary value (`injured_or_sick`, `food_needed`, `water_needed`, `unsafe_location`, `trapped`) with its turkish label; a post-#101 mark serves the fixed pair `"unspecified"` / `"Yardıma ihtiyacı var"`. they are removed only once 0.1 clients are retired. the alert's source is the cat's latest non-deleted help-carrying update (a cleared or soft-deleted mark stops being a source and the previous still-active mark, if any, takes over — see [[db]]). the object's mere presence already means "active": the server derives that by comparing `expires_at` against its own clock at request time, so a client is never asked to make that comparison itself — an expired state is never served as active, regardless of any client clock.

`area_label` is a nullable, human-readable display-only location string set at cat creation or seed time. coordinates remain the source of truth.

### traits (dormant legacy storage)

issue #42 removed permanent cat traits from the mvp surface. behavioral observations such as playful, shy, or friendly belong in update comments ([[updates]]), not permanent profile attributes.

### updates

an update is an authenticated contribution that may carry structured statuses, the help flag (`yardıma ihtiyacı var` — issue #101, contract issue #100), or both in one record. the create invariant is "at least one status, or `needs_help: true`"; comment-only requests remain invalid.

```
GET    /v1/cats/{cat_id}/updates?cursor=&limit=   (optional Bearer)   → { items: [{ id, kind, statuses[], comment|null, created_at,
                                                              needs_help, needs_help_category|null, needs_help_category_label|null,
                                                              needs_help_expires_at|null, needs_help_active|null,
                                                              author_is_me, correction_expires_at|null }],
                                                     next_cursor|null }
POST   /v1/cats/{cat_id}/updates     (Bearer required; X-Device-Token optional; Idempotency-Key optional)  { statuses[]?, needs_help?, comment? }
                                                                                → 201 { id, kind, statuses[], comment|null, created_at, needs_help,
                                                                                        needs_help_category|null, needs_help_category_label|null,
                                                                                        needs_help_expires_at|null, needs_help_active|null,
                                                                                        author_is_me, correction_expires_at }   (needs_help — issue #101)
POST   /v1/cats/{cat_id}/needs-help  (Bearer required)  { category, comment? }    → 201 { id, kind, comment|null, created_at, needs_help,
                                                                                        needs_help_category, needs_help_category_label,
                                                                                        needs_help_expires_at, needs_help_active }  (0.1 compat — see below)
PATCH  /v1/cats/{cat_id}/updates/{update_id}  (Bearer required)  { statuses[]?, needs_help?, comment? }  → 200 { id, kind, statuses[], comment|null,
                                                                                                    created_at, updated_at, needs_help, ...,
                                                                                                    author_is_me, correction_expires_at }   (implemented — issue #80/#101)
DELETE /v1/cats/{cat_id}/updates/{update_id}  (Bearer required)                             → 204   (implemented — issue #80)
POST /v1/media                      (Bearer required; X-Device-Token optional; Idempotency-Key optional)  multipart file, muted (optional, default true) → 201 { media_id, url, muted }  (implemented — issue #70; muted added by issue #194)
GET  /v1/media/objects/{key}                                                    → the object's raw bytes  (implemented — issue #70)
```

`GET /v1/cats/{cat_id}/updates` is implemented (issue #21, extended in #23), newest first and keyset-paginated on `(created_at, seq)`. `OptionalBearer` (issue #80) resolves the caller's own account when a valid bearer is presented, without requiring one — a guest read is unaffected. `author_is_me` is `true` only when the caller's own account id matches the entry's author; `correction_expires_at` is non-null only when `author_is_me && kind == 'ordinary'` (`created_at + 10m`, docs/product/updates.md's fixed window) and is present purely so the client can show the correction affordance/countdown without guessing ownership — the server remains the sole authority on whether an actual correction succeeds. A soft-deleted update (see below) is excluded from this list entirely, for every reader including its own author.

`POST /v1/cats/{cat_id}/updates` resolves the authenticated account from `Authorization: Bearer` (implemented — issue #65, superseding #36's earlier device-token-only contract); `X-Device-Token` may still be supplied and is recorded alongside the account for installation/abuse-control association, but is never sufficient authorization on its own. `statuses` values come from `seen`, `fed`, and `water_provided`; since issue #101 the set may be empty when `needs_help: true` is present — the invariant is "at least one status or the help flag", and comment-only requests remain invalid. `needs_help: true` marks the cat's help state: `needs_help_expires_at` is server-computed as `created_at + 72h` (never client-supplied), `needs_help_active` is decided server-side against the service clock on every read, and the comment doubles as the optional help note, capped at 500 unicode characters (`400` beyond it, per the issue #100 contract; an ordinary comment is not capped by this rule). no category is accepted or stored on this path. the server derives author (account and, optionally, device) and timestamps and writes the update, statuses, `last_update_at`, and notification outbox entry transactionally. `author_is_me` is always `true` and `correction_expires_at` always `created_at + 10m` on this response (issue #80) — the caller always authored what they just created, and it's always freshly inside its own correction window — so the client can show the correction affordance immediately, without waiting for a reload.

wire `kind` (issue #101) is derived from the flag — `"needs_help"` whenever `needs_help` is true, `"ordinary"` otherwise — so a 0.1 client renders any help-carrying entry through its needs-help branch (help pill, statuses ignored, correction menu hidden): the safe degradation for a combined update. a 0.2 client reads `needs_help`/`statuses` directly and ignores `kind`. on a help-carrying entry, `needs_help_category`/`needs_help_category_label` are always non-null for 0.1 compatibility: a legacy record serves its stored vocabulary value and its turkish label; a post-#101 mark serves the fixed pair `"unspecified"` / `"Yardıma ihtiyacı var"` (a 0.1 client's analytics clamps `"unspecified"` to its existing `unknown` bucket, so no invalid closed-enum value is ever emitted).

re-marking while a help state is already active (product-owner decision on the #100 contract's open question, implemented in #101; hardened by #105): the write succeeds and the 72h window restarts from the newer mark, but followers are **not** notified again — notification eligibility is decided atomically at update creation time, inside the same transaction as the write, and frozen into the outbox row (see [[db]]'s `needs_help_eligible`). the worker never re-derives it at dispatch time, so a delayed dispatch reaches the same verdict a prompt one would, and later deletion or correction of the earlier active mark cannot turn the newer mark's suppressed enqueue into a push.

`POST /v1/cats/{cat_id}/needs-help` (issue #78; since #101 a 0.1 compatibility endpoint kept through the mixed-version window) requires bearer authentication; `X-Device-Token` is optional installation/abuse-control association only. `category` must still be one of the fixed 5-value legacy vocabulary — 0.1 clients only ever send those — and is recorded as legacy metadata only, never rendered by 0.2 clients. the write itself is the unified flag-model write (`kind = 'ordinary'`, `needs_help = true`, no statuses), so a mark made here is clearable/deletable by its author exactly like one made through `POST .../updates`, and the request/response contract a 0.1 client sees is unchanged. retiring this endpoint is deferred until 0.1 clients are retired.

`PATCH`/`DELETE /v1/cats/{cat_id}/updates/{update_id}` (implemented — issue #80, extended by #101) let the author correct or soft-delete their own update within the fixed 10-minute window (docs/product/updates.md). Authorization (author match), the window check, and concurrency safety are all enforced in a single conditional sql update statement (see [[db]]) rather than separate read-then-write checks, so a stale or duplicate retry can't race past expiry or overwrite newer state. `kind`, author identity, and `created_at` are never alterable through either path — `PATCH` changes `statuses`/`comment` and (issue #101) may **clear** the help mark. **every `PATCH` field is presence-aware (issue #105): an omitted field preserves the row's existing value** — a body carrying only `{"needs_help": false}` removes the mark without touching statuses, comment, or any other update data. `statuses` absent (or JSON `null`) preserves the existing set; an explicit `[]` clears it, valid only while the help flag survives; a supplied set replaces and validates exactly as before. `comment` absent preserves; an explicit `null` clears; a string replaces. `needs_help` is three-state — absent leaves the mark untouched (a 0.1 client's PATCH never carries it), `false` removes the mark (flag, expiry, and any compat-recorded category nulled together; the cat's active state falls back to the newest remaining still-active mark, if any), and `true` answers `400` — help is only ever marked at creation, never added by an edit, so there is never a retroactive notification to fan out. the post-state must still satisfy the create invariant (at least one status, or the flag survives), evaluated against the replacement set when one was supplied and the preserved set otherwise; a patch that would leave neither answers `400` — the author deletes the update instead. `DELETE` only ever sets `deleted_at`, never removing the row (see [[db]]); deleting a help-carrying update within the window likewise removes it as the active state's source. a legacy pre-#101 needs-help subtype row remains non-correctable — attempting either verb against one answers `404`, identically to an update id that doesn't exist under this `cat_id` (every post-#101 row, help-carrying or not, is correctable by its author in-window). Error taxonomy: `400` malformed body/invalid statuses/hollow post-state/`needs_help: true`, `401` missing/invalid bearer, `403` the update exists under this cat but isn't the caller's own (not collapsed into `404` — the full history is already public per [[privacy]], so confirming "exists, but isn't yours" leaks nothing a guest couldn't already see), `404` unknown update/legacy needs-help subtype, `410` the window has closed (mirrors the existing otp/verify `410` convention). A retry against an already-deleted row answers success (`204`), not an error — the same idempotent-retry convention this api already uses for `POST /v1/auth/logout` and `POST /v1/me/notifications/{id}/read`.

`DELETE` additionally answers `409` when the update's attached media is still the cat's current cover (`cats.primary_photo_id`) — product decision: a cover image must never disappear implicitly as a side effect of deleting its source update, so the owner promotes a different `GET /v1/cats/{cat_id}/media` entry via `PATCH .../cover` first, then retries the delete. The guard and the delete run in the same conditional sql statement as every other authorization/expiry check above (see [[db]]), so there's no window for a concurrent cover change to race past it. Cover media is never implicitly cleared or replaced by this endpoint — only the delete itself is refused.

`POST /v1/media` (issue #70; extended by issue #153's update-attached photo and video flow) is standalone media upload — independent of cat creation (a cat's own required initial photo is instead embedded directly in `POST /v1/cats`, above, and stays image-only). Validation, ownership resolution, and `Idempotency-Key` handling are identical to `POST /v1/cats`'s photo for images (same shared pipeline, see [[backend]]). This endpoint additionally accepts a narrow, pass-through-validated video: a recognized mp4/mov container (`ftyp` major_brand `isom`/`mp42`/`mp41`/`M4V `/`qt  `) no longer than 30 seconds, per the file's own `moov`/`mvhd` duration — never a client-supplied value. No transcoding is performed for this first version; the uploaded bytes are stored as-is. An oversized upload answers `413`, a recognized-but-too-long video answers `400 {"error":"video too long"}`, and anything that's neither a decodable jpeg/png nor a recognized video container answers `400 {"error":"malformed file"}`. `POST /v1/cats/{cat_id}/updates` may carry an optional `media_id` referencing a row the same authenticated account just uploaded here; the update write resolves that id, rejects an unknown-or-not-owned media row as `404 {"error":"media not found"}`, and surfaces the attached media back as `photo_url` plus `media_content_type` on the created update and later `GET .../updates` reads — the client tells a video apart from a photo by checking whether `media_content_type` starts with `video/`.

`POST /v1/media`'s optional `muted` form field (issue #194's product decision: short-form videos default to muted, with an explicit opt-in to audio) defaults `true` when absent or unparseable — a video is muted unless the composer's toggle explicitly sends `muted=false`; meaningless for a photo but accepted the same way regardless, and echoed back as `muted` on the upload response. The stored flag is not enforced by re-encoding — see [[backend]]'s "no transcoding" decision and its accepted limitation — it is read back as `media_muted` alongside `photo_url`/`media_content_type` on `GET .../updates` and `GET /v1/cats/{cat_id}/media`, and every video playback surface in the app honors it.

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

both are own-account-only this mvp slice — there is no `GET /v1/users/{id}/profile` or any other route exposing another account's profile; issue #80's acceptance criteria describes viewing one's own surface, not a public profile-viewing feature. `display_name` is nullable (an account that never completed the new-account display-name step). `badges` is always all 5 fixed mvp badges (docs/product/badges.md), earned or not, in the same fixed order — never a filtered or reordered list; `earned_at` is non-null only when `earned`. `recent_contributions` is a fixed-size (8), newest-first list capped server-side — `statuses`/`needs_help_category`/`needs_help_category_label` mirror `GET .../updates`'s own shape exactly (including issue #101's rule: a help-carrying entry's `type` is `help` and its category fields serve the stored legacy value or the fixed `"unspecified"` compat pair), so the client composes display copy for a recent contribution the same way it already does for the cat-detail timeline, rather than the server pre-composing a label string. everything here is derived server-side from the account's own `updates`/`cats` rows at request time (see [[db]]) — never a client-supplied counter, badge id, or timestamp.

curated profile avatars (mentioned in docs/product/community.md/privacy.md) are explicitly deferred past this slice: no avatar field exists in this response and no avatar-selection endpoint exists — there is no defined curated set (asset list, count, or picker) anywhere in the product/design references to build against yet. a future slice adds this once that set is defined.

### reports

```
POST /v1/reports  (Bearer required)  { target_type, target_id, reason, note? }
                                              → 201 { id, target_type, target_id, reason, note|null, status, created_at }
                                              (implemented — issue #233)
```

user-generated content reporting (docs/product/trust.md, docs/product/privacy.md): a cat, an update, or a media item may be reported by any phone-verified account. `reporter_user_id` is always resolved from `Authorization: Bearer` — never accepted from the request body, so a report's ownership can't be spoofed. reporting never mutates the reported content: this endpoint writes only a `reports` row (see [[db]]) — it never touches `cats.status`, `updates.deleted_at`, or any `media` field, and there is no automatic hide-after-N-reports behavior in this version.

`target_type` is exactly one of `cat`, `update`, `media`; any other value is `400`. `target_id` must be a well-formed uuid (`400` otherwise) and must resolve to a real, still-visible row of that type — a soft-deleted cat or update is treated the same as an unknown id (`404`), matching how every other read/write path already excludes them (see [[db]]'s `CatExists`/`UpdateExists`); a media row has no soft-delete state of its own, so existence alone gates it. A malformed `target_id` and a well-formed-but-unknown/deleted one are deliberately distinct statuses (`400` vs. `404`) rather than collapsed into one, mirroring `GET /v1/cats/{cat_id}`'s own malformed-vs-unknown-id split.

`reason` is the fixed, closed vocabulary a database check constraint also enforces (product-owner decision on issue #233; turkish labels are used verbatim in the flutter client, not composed server-side):

```
inappropriate  -> "uygunsuz icerik"
not_a_cat      -> "kedi degil"
wrong_info     -> "yanlis bilgi"
spam           -> "spam / tekrar eden icerik"
privacy        -> "kisisel gizlilik ihlali" (medyada insan yuzu, ev ici, ozel alan, plaka gibi)
other          -> "diger"
```

any other value is `400`. `other` requires `note` to be present and non-blank after trimming (`400` otherwise, before the note ever reaches the database — the check constraint is the last line of defense, not the primary one); every other reason leaves `note` optional. `note` is free text with no fixed cap beyond ordinary request-size limits.

retries/duplicates are idempotent (issue #233 acceptance): a second `POST` from the same account against the same `(target_type, target_id)` while an earlier report from that account against it is still `status = 'open'` returns the original report (`201`, not `409` or `200` — the response shape is identical either way, so a client can't tell a fresh report from a resurfaced one, which is the point) rather than creating a second active row. Submitting again after the original resolves is a new, independent report — see [[db]]'s partial unique index.

`status` starts `open` and can only become `resolved` through direct maintainer action against the table itself — no endpoint in this version reads or writes it, since 0.4 ships no moderator/admin dashboard (see "out of scope" below and [[trust]]). Error taxonomy: `400` malformed body/unknown `target_type`/malformed `target_id`/invalid `reason`/missing `note` on `other`, `401` missing/invalid bearer, `404` an unknown or soft-deleted target.

### blocks

```
POST   /v1/me/blocks             (Bearer required)  { blocked_user_id }  → 204
DELETE /v1/me/blocks/{user_id}   (Bearer required)                       → 204
GET    /v1/me/blocks             (Bearer required)                       → 200 [ { user_id, display_name|null, created_at } ]
                                                                         (implemented — issue #234)
```

account-to-account blocking (docs/product/trust.md, docs/product/privacy.md). the blocker is always resolved from `Authorization: Bearer` — the request body has no field for it and any extra field is rejected outright (`400`), so a block can't be attributed to another account. blocking lives under `/v1/me/` because a block is the caller's own state: `GET /v1/me/blocks` is the only read that returns blocks at all, and it is always scoped to the caller. the blocked account is never notified and cannot discover the block through any endpoint.

both writes are idempotent: blocking an already-blocked account and unblocking one that isn't blocked both answer `204` and change nothing — the end state the caller asked for is the state they get. `400` covers a malformed `blocked_user_id` and an attempt to block yourself; `404` covers a well-formed id that is not an account.

blocking is **visibility filtering, never deletion**. no content is removed, no `cats.status` or `updates.deleted_at` is touched, and unblocking restores exactly what was hidden — including follows, which survive a block untouched. what a block hides, for the blocker only, is every cat *owned* by the blocked account (`cats.created_by_user_id`) and therefore everything reachable through those cats: markers, detail, updates, media, and other accounts' contributions attached to them. it does not hide that account's updates or media on cats someone else owns; the product decision (issue #234) is owner-scoped, not author-scoped.

enforcement is server-side on every read, never client-side filtering. the filtered surfaces are `GET /v1/cats` (map), `GET /v1/cats/nearby` (duplicate candidates), `GET /v1/cats/discover` (both filters), `GET /v1/me/follows`, `GET /v1/cats/{cat_id}`, `GET /v1/cats/{cat_id}/updates`, and `GET /v1/cats/{cat_id}/media`. a hidden cat answers exactly like an unknown id (`404`) rather than a distinguishable "blocked" error — the same indistinguishability a soft-deleted cat already has, so a response never reveals that a cat exists and was filtered. writes follow the same rule: following a hidden cat, posting an update to it, and reporting it all answer `404`.

the four previously-unauthenticated read routes (`/v1/cats`, `/v1/cats/nearby`, `/v1/cats/discover`, `/v1/cats/{cat_id}/media`) gained `OptionalBearer` for this: they stay guest-readable and a guest's results are byte-for-byte what they were before blocking existed, but an authenticated caller has to be resolvable for the filter to apply at all.

`GET /v1/cats/{cat_id}` gained `owner_user_id`, each update in `GET /v1/cats/{cat_id}/updates` gained `author_user_id`, and each item in `GET /v1/cats/{cat_id}/media` gained `uploader_user_id` — all nullable (a seed cat has no owner; content predating accounts has no author/uploader). the client needs them to know *which account* a block action would act on; `is_owner`/`author_is_me` only answer whether it is the caller.

notification fan-out honours blocks too: a follower who blocks a cat's owner is dropped from that cat's needs-help recipients, so a block never leaves a push arriving that deep-links into a screen the same account now gets `404` for. rows already queued in `notification_outbox` when the block happens are left alone (issue #234).

### modeling notes

- a cat's active alert is derived from its latest non-deleted, non-expired help-carrying update (`needs_help = true` — issue #101's combined flag model; the legacy `kind` subtype no longer drives any read path).
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
