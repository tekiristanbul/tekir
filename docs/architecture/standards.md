# standards

## goal

record which open, vendor-neutral standards tekir actually implements, and
classify the ones it does not by whether they are required, useful later, or not
needed. this is an inventory of the shipped codebase, not a wish list — every
"in use" row names a file that proves it.

written in issue #271.

## decisions

- when a problem already has an open standard, tekir uses it rather than
  inventing an equivalent. the standard is named in the code or in the contract
  document, not assumed.
- a vendor's api is wrapped behind an application-owned interface, and the
  application depends on the standard rather than the vendor's sdk where one
  exists — object storage is the s3 api, not a digitalocean sdk; push is fcm
  http v1 authenticated with a standard oauth2 service-account flow.
- a standard is adopted when it removes work or ambiguity, not for conformance
  as such. the follow-up table below states why each unadopted standard is not
  adopted yet.

## in use

### identity and transport

| standard | where |
| --- | --- |
| rfc 7519 json web token — hs256 access tokens, `sub`/`iat`/`exp` registered claims, non-hmac algorithms rejected | `backend/internal/service/session.go` |
| rfc 6750 bearer token usage — `Authorization: Bearer <token>`, header shape only | `backend/internal/handler/bearer_auth.go` |
| rfc 7523 jwt profile for oauth 2.0 client authentication — service-account flow to fcm http v1 | `backend/internal/service/fcm_notification_sender.go`, `golang.org/x/oauth2/google` |
| e.164 phone numbers — normalized to `+90XXXXXXXXXX`; a non-turkish country code is rejected, not guessed | `backend/internal/service/phone.go` |
| rfc 4648 base64url, fips 180-4 sha-256, rfc 2104 hmac — device and refresh tokens are csprng-generated, transported base64url, stored only as sha-256 hashes | `backend/internal/service/session.go` |
| rfc 4122 uuid — every primary key, via `gen_random_uuid()` and `google/uuid` | `backend/db/migrations/`, `backend/internal/repository/` |

### http

| standard | where |
| --- | --- |
| http status semantics — 16 distinct codes in use, including 409, 410, 413, 415, 422, 429 | `backend/internal/handler/` |
| rfc 7578 multipart/form-data — media upload, size-bounded before decode | `backend/internal/handler/cats.go` |
| cors — configurable allowed origins plus the application's own `X-Device-Token` and `Idempotency-Key` headers | `backend/internal/server/router.go`, `backend/internal/config/config.go` |
| `Cache-Control: no-store` on auth, device, and profile responses | `backend/internal/handler/auth.go`, `devices.go`, `profile.go` |
| `X-Content-Type-Options: nosniff` on served media | `backend/internal/handler/media_serve.go` |
| `Idempotency-Key` (ietf draft, not a published rfc) — client-generated opaque key on cat creation, media upload, and updates, backed by partial unique indexes | [[api]], `backend/db/migrations/00017`, `00021` |
| rfc 3339 / iso 8601 timestamps — every api timestamp, produced by go's `encoding/json` and consumed by dart's `DateTime.parse` | `backend/internal/handler/`, `app/lib/**/data/` |

### geo

| standard | where |
| --- | --- |
| wgs84 / epsg:4326 — the storage and wire coordinate reference system | `backend/db/migrations/00003_create_cats.sql` |
| postgis — `geography(point, 4326)` with a gist index; `st_dwithin`, `st_distance`, bounding-box predicates evaluated in the database | `backend/db/queries/cats.sql`, [adr-0002](../adr/0002-postgis-geography-as-the-location-primitive.md) |

### media

| standard | where |
| --- | --- |
| cipa dc-008 / exif 2.32 — orientation is parsed with a hand-rolled tiff/ifd0 reader, applied as a pixel transform, then stripped by the re-encode | `backend/internal/service/media.go` |
| jpeg / png decode and re-encode; iso base media file format `ftyp` box sniffing for `video/mp4` | `backend/internal/service/media.go` |
| aws signature version 4 over the s3 api — signed locally over `net/http`, no aws sdk, so any s3-compatible endpoint works | `backend/internal/service/s3_object_store.go` |

### client and web platform

| standard | where |
| --- | --- |
| w3c web app manifest — name, start url, display, theme color, orientation, 192/512 icons including `purpose: maskable` | `app/web/manifest.json` |
| service worker — background push only; there is no offline or caching worker | `app/web/firebase-messaging-sw.js` |
| opengraph, twitter cards, `rel="canonical"` | `website/index.html`, `website/privacy.html` |

### project and delivery

| standard | where |
| --- | --- |
| oci container images — multi-stage builds, non-root uid | `backend/Dockerfile`, `backend/Dockerfile.notifier`, `app/Dockerfile.web` |
| semantic versioning — `MAJOR.MINOR.PATCH+BUILD`, where `+N` is the shared android version code and ios build number | `app/pubspec.yaml` |
| conventional commits — a narrowed variant, mechanically enforced: fixed type list, ≤50-character subject, ≤72-column body, english only, no ai authorship trailers | `.githooks/commit-msg`, [`CONTRIBUTING.md`](../../CONTRIBUTING.md) |
| spdx license identifier `MIT` — as the license file, not as per-file headers | [`LICENSE`](../../LICENSE) |
| kubernetes-style liveness/readiness endpoints `GET /healthz`, `GET /readyz` — a widespread convention rather than a published spec | `backend/internal/server/router.go` |

## partial

| standard | state |
| --- | --- |
| wcag / wai-aria | the marketing site uses `aria-label`, `aria-labelledby`, and `aria-hidden` deliberately. the flutter app has only a handful of `Semantics` wrappers and there is no conformance target anywhere. |
| utc normalization | every timestamp column is `timestamptz`, so storage is unambiguous, but explicit `.UTC()` normalization appears only in cursor encoding and sigv4 signing. |

## follow-up

not adopted yet. each row states why, so this table doubles as the gap
classification. none of these is required for the current release.

| standard | why not yet |
| --- | --- |
| openapi 3.1 | the api contract is 250+ lines of prose in [[api]], and the go handlers and the dart client hand-write the same shapes independently — drift is caught only by tests. a spec is the single highest-value interoperability gap, but generating it is its own change, and without a ci drift gate it would go stale immediately. |
| rfc 7807 problem+json | errors are `{"error": "<string>"}` and the flutter client switches on that text. moving to problem+json is a breaking response-shape change on both sides, not a documentation task. |
| geojson | coordinates are flat `{lat, lng}` and the map bounding box is a bare csv `bbox`. storage is already standard wgs84, so a geojson representation is an additive api change whenever an external consumer needs one. today there is none. |
| rfc 8288 web linking | pagination is an opaque `next_cursor` in the body. `Link` headers would add a second, redundant way to say the same thing with no consumer asking for it. |
| etag / conditional requests | no read endpoint currently sets a validator. worth doing when map and detail reads become a measured cost, not before. |
| bcp 47 + arb localization | the product is turkish-only by decision, and all copy is hardcoded dart strings with hand-written relative-time and distance formatters. this is the largest standards gap in the client and becomes required the moment a second language is real. |
| rfc 9116 `security.txt` | [`SECURITY.md`](../../SECURITY.md) already routes reports and github surfaces it. a `.well-known/security.txt` needs a maintained `Expires` field, which is recurring upkeep for a duplicate of what already exists. |
| openmetrics / prometheus | [[backend]] intends metrics; none are implemented and there is no `/metrics` endpoint. structured `log/slog` json is the whole observability surface today. |
| opentelemetry | tracing is explicitly out of scope for mvp — one api process, one worker, one database. |
| json-ld / schema.org, robots.txt, sitemap.xml | marketing-site seo, unrelated to the application contract. |
| spdx per-file headers, sbom | a single MIT license file covers a single-repository project with no redistribution story. |

## interoperability

tekir's domain model already contains the concepts a street-animal-care
interoperability specification would need: a cat, a location
(`geography(point, 4326)`), an update carrying structured statuses (`seen`,
`fed`, `water_provided`), a needs-help flag with a category and an expiry, and
media.

no such specification is defined, and none should be until there is a concrete
external consumer — a municipality, an ngo, another application, or an open-data
integration that has actually asked. the project has no forks and no external
integrations today. inventing a protocol without a consumer would create a
compatibility surface with all of the maintenance cost and none of the benefit.

if a real consumer appears, the first step is an openapi description of the
existing `/v1` surface (see the follow-up table), not a new vendor-neutral schema
— the existing api is the thing they would integrate against.

## out of scope

- api versioning strategy beyond the `/v1` prefix; see [[api]].
- conformance certification or a published conformance statement for any
  standard listed here.
