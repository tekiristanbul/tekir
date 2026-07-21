# api

## goal

define the http api surface for the cats istanbul mvp backend, matching the product decisions in `docs/product/*.md` and the schema in [[db]].

## decisions

### identity / auth model

two-tier, matching [[trust]] and the mvp scoping conversation: following a cat and posting a text-only update need no login; login (phone otp) is required only when adding a photo/video (including new-cat creation, since a photo is mandatory there).

- **anonymous device identity** (`device_id`, client-generated uuid + push token), sent as `X-Device-Id` on every request. sufficient for following and text-only updates.
- **account** (phone-verified), obtained via otp. the resulting `access_token` (jwt) is sent as `Authorization: Bearer` alongside `X-Device-Id`. verifying links the device's existing follows/updates to the account automatically (same `device_id`, no separate merge call needed).

```
POST /v1/devices                     { push_token, platform }         → { device_id }
POST /v1/auth/otp/request            { phone }                        → 202
POST /v1/auth/otp/verify             { phone, code, device_id }       → { access_token, user_id }
GET  /v1/me                          (X-Device-Id, optional Bearer)   → { device_id, user_id|null, phone_verified }
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

```
GET  /v1/cats/{cat_id}/updates?cursor=      → [{ id, type: status|help_request, comment|null, media_id|null, created_at }]  (newest first)
POST /v1/cats/{cat_id}/updates              { type, comment?, media_id? }
                                             (media_id present → Bearer required; absent → X-Device-Id alone is enough)
POST /v1/media           (Bearer required)  multipart file → { media_id, url }
```

### follows / notifications

```
POST   /v1/cats/{cat_id}/follow      (X-Device-Id is enough)   → 204
DELETE /v1/cats/{cat_id}/follow                                 → 204
GET    /v1/me/follows                                           → [cat...]
GET    /v1/me/notifications?cursor=                              → [{ id, cat_id, update_id, read, created_at }]
POST   /v1/me/notifications/{id}/read                            → 204
```

push delivery is not client-facing — it's triggered server-side against the `push_token` registered on the device (see [[backend]]).

### modeling notes

- `cat.needs_help` is derived: the latest update is `help_request` and hasn't expired. the expiry duration is unresolved (see [[alerts]] open question) and is left as a config value, not a hardcoded number.
- `update.comment` (the content of a `status` update) is free text for now. [[updates]] / [[principles]] treat "latest status" as eventually structured, but no enum exists yet — kept as a plain column so a later `status_code` enum can be added without a schema break.
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
