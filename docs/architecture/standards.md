# standards and interoperability inventory

## goal

record what tekir actually builds on — published standards, public
specifications, and widely-followed conventions alike — and classify what it does
not use by whether that gap is required, useful later, or not needed. this is an
inventory of the shipped codebase, not a wish list: every "in use" row names a
file that proves it.

written in issue #271.

## what the `kind` column means

not everything worth recording here is an open standard, and calling a
convention a standard would overstate what the project conforms to. each row is
one of:

- **standard** — published and maintained by a recognized standards body: ietf,
  w3c/whatwg, iso, itu-t, ogc, nist, cipa.
- **specification** — a public, versioned, openly readable specification without
  a standards body behind it, including de-facto ones a vendor published and
  everyone implements.
- **convention** — a widespread practice with no normative document. tekir
  follows it because readers expect it, not because anything defines it.
- **technology** — an implementation the project depends on, listed because of
  the standard it carries.

conformance is not claimed for any row. "in use" means the codebase implements
the thing named, not that it has been tested against a conformance suite.

## decisions

- when a problem already has an open standard, tekir uses it rather than
  inventing an equivalent. the standard is named in the code or in the contract
  document, not assumed.
- a convention is recorded as a convention. the project does not describe
  something as a standard because it is common.
- a vendor's api is wrapped behind an application-owned interface, and the
  application depends on the standard rather than the vendor's sdk where one
  exists — object storage is the s3 api, not a digitalocean sdk; push is fcm
  http v1 authenticated with a standard oauth2 service-account flow.
- a standard is adopted when it removes work or ambiguity, not for conformance
  as such. the follow-up table below states why each unadopted standard is not
  adopted yet.

## in use

### identity and transport

| what | kind | where |
| --- | --- | --- |
| rfc 7519 json web token — hs256 access tokens, `sub`/`iat`/`exp` registered claims, non-hmac algorithms rejected | standard | `backend/internal/service/session.go` |
| rfc 6750 bearer token usage — the `Authorization: Bearer <token>` header shape only; tekir is not an oauth 2.0 authorization server | standard | `backend/internal/handler/bearer_auth.go` |
| rfc 7523 jwt profile for oauth 2.0 client authentication — service-account flow to fcm http v1 | standard | `backend/internal/service/fcm_notification_sender.go`, `golang.org/x/oauth2/google` |
| itu-t e.164 phone numbers — normalized to `+90XXXXXXXXXX`; a non-turkish country code is rejected, not guessed | standard | `backend/internal/service/phone.go` |
| rfc 4648 base64url, fips 180-4 sha-256, rfc 2104 hmac — device and refresh tokens are csprng-generated, transported base64url, stored only as sha-256 hashes | standard | `backend/internal/service/session.go` |
| rfc 4122 uuid — every primary key, via `gen_random_uuid()` and `google/uuid` | standard | `backend/db/migrations/`, `backend/internal/repository/` |

### http

| what | kind | where |
| --- | --- | --- |
| rfc 9110 http semantics — 16 distinct status codes in use, including 409, 410, 413, 415, 422, 429 | standard | `backend/internal/handler/` |
| rfc 7578 multipart/form-data — media upload, size-bounded before decode | standard | `backend/internal/handler/cats.go` |
| cors (whatwg fetch) — configurable allowed origins plus the application's own `X-Device-Token` and `Idempotency-Key` headers, which are themselves application-defined, not standard | standard | `backend/internal/server/router.go`, `backend/internal/config/config.go` |
| rfc 9111 `Cache-Control: no-store` on auth, device, and profile responses | standard | `backend/internal/handler/auth.go`, `devices.go`, `profile.go` |
| `X-Content-Type-Options: nosniff` on served media | specification | `backend/internal/handler/media_serve.go` |
| `Idempotency-Key` — client-generated opaque key on cat creation, media upload, and updates, backed by partial unique indexes. an expired ietf draft, not a published rfc | specification | [[api]], `backend/db/migrations/00017`, `00021` |
| rfc 3339 / iso 8601 timestamps — every api timestamp, produced by go's `encoding/json` and consumed by dart's `DateTime.parse` | standard | `backend/internal/handler/`, `app/lib/**/data/` |
| opaque-cursor keyset pagination — `?cursor=&limit=` in, `{"items": [...], "next_cursor": null}` out. an application-defined shape, not a standard one | convention | `backend/internal/handler/cats.go` |

### geo

| what | kind | where |
| --- | --- | --- |
| wgs84 / epsg:4326 — the storage and wire coordinate reference system | standard | `backend/db/migrations/00003_create_cats.sql` |
| postgis — the dependency that carries ogc simple features and the epsg:4326 datum into the database: `geography(point, 4326)` with a gist index, `st_dwithin`, `st_distance`, bounding-box predicates | technology | `backend/db/queries/cats.sql`, [adr-0002](../adr/0002-postgis-geography-as-the-location-primitive.md) |

### media

| what | kind | where |
| --- | --- | --- |
| cipa dc-008 / exif 2.32 — orientation is parsed with a hand-rolled tiff/ifd0 reader, applied as a pixel transform, then stripped by the re-encode | standard | `backend/internal/service/media.go` |
| itu-t t.81 jpeg, w3c png, iso/iec 14496-12 base media file format — decode and re-encode for images, `ftyp` box sniffing for `video/mp4` | standard | `backend/internal/service/media.go` |
| aws signature version 4 over the s3 api — signed locally over `net/http`, no aws sdk, so any s3-compatible endpoint works. a vendor specification everyone implements, not a standards-body document | specification | `backend/internal/service/s3_object_store.go` |

### client and web platform

| what | kind | where |
| --- | --- | --- |
| w3c web application manifest — name, start url, display, theme color, orientation, 192/512 icons including `purpose: maskable` | standard | `app/web/manifest.json` |
| w3c service workers — background push only; there is no offline or caching worker | standard | `app/web/firebase-messaging-sw.js` |
| opengraph and twitter cards (vendor-published, universally consumed); `rel="canonical"` is whatwg html | specification | `website/index.html`, `website/privacy.html` |

### project and delivery

| what | kind | where |
| --- | --- | --- |
| oci image format — multi-stage builds, non-root uid. open governance under the linux foundation rather than a traditional standards body | specification | `backend/Dockerfile`, `backend/Dockerfile.notifier`, `app/Dockerfile.web` |
| semantic versioning 2.0.0 — `MAJOR.MINOR.PATCH+BUILD`, where `+N` is the shared android version code and ios build number. a public specification with no standards body | specification | `app/pubspec.yaml` |
| conventional commits — a narrowed variant, mechanically enforced: fixed type list, ≤50-character subject, ≤72-column body, english only, no ai authorship trailers. the narrowing means tekir is not conformant, deliberately | specification | `.githooks/commit-msg`, [`CONTRIBUTING.md`](../../CONTRIBUTING.md) |
| spdx license identifier `MIT` — as the license file, not as per-file headers | specification | [`LICENSE`](../../LICENSE) |
| liveness and readiness endpoints `GET /healthz`, `GET /readyz` — nothing defines these paths; they are named this way because operators expect it | convention | `backend/internal/server/router.go` |

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
