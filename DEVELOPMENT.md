# development

this guide is for contributors running tekir locally, maintainers working on the go api or flutter client, and anyone reproducing ci failures.

## prerequisites

- docker with docker compose
- [go `1.26.4`](https://go.dev/dl/#go1.26.4), as declared by [`backend/go.mod`](backend/go.mod); this version was released on june 2, 2026
- a flutter installation providing dart `^3.12.2`, as declared by [`app/pubspec.yaml`](app/pubspec.yaml)
- a google maps javascript api key for the flutter web map

### tool versions and asdf

this repository does not currently contain a `.tool-versions` file. asdf may still be used locally, but versions must match the declarations above rather than an assumed repository-level pin.

verify the installed tools:

```text
go version
flutter --version
dart --version
docker compose version
```

## local services

start postgres/postgis and the api from the repository root:

```text
docker compose up -d
```

this uses [`docker-compose.yml`](docker-compose.yml) and exposes:

- postgres on `localhost:5432`
- api on `localhost:8080`

use alternate host ports when either default is occupied:

```text
POSTGRES_PORT=5433 API_PORT=8081 docker compose up -d
```

inspect or stop the services:

```text
docker compose ps
docker compose logs -f api
docker compose down
```

remove the local database volume only when a clean database is intentionally required:

```text
docker compose down -v
```

## database migrations

backend database commands use this default local connection:

```text
postgres://catsofistanbul:catsofistanbul@localhost:5432/catsofistanbul?sslmode=disable
```

apply migrations:

```text
cd backend
make migrate-up
```

inspect migration state or roll back one migration:

```text
cd backend
make migrate-status
make migrate-down
```

set `DATABASE_URL` explicitly when postgres is exposed on another port or host:

```text
cd backend
DATABASE_URL='postgres://catsofistanbul:catsofistanbul@localhost:5433/catsofistanbul?sslmode=disable' make migrate-up
```

migrations live in [`backend/db/migrations/`](backend/db/migrations/). sqlc queries live in [`backend/db/queries/`](backend/db/queries/).

## seed data

load the repeatable local fixture data after migrations:

```text
cd backend
make seed
```

## backend development

common commands from [`backend/Makefile`](backend/Makefile):

```text
cd backend
make run
make build
make test
make lint
make fmt
make sqlc
```

health endpoints for the locally running api:

```text
curl http://localhost:8080/healthz
curl http://localhost:8080/readyz
```

`goose`, `sqlc`, and `golangci-lint` are invoked through go tool dependencies; do not install unrelated global versions to work around a repository failure.

## otp providers

`OTP_PROVIDER` selects how login codes are delivered and checked:

- `fake` (local default): deterministic, no network. the code is logged by the api process; no twilio account needed. this is what `make run`, docker compose, and the automated tests use.
- `twilio`: real sms through twilio verify. requires `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and `TWILIO_VERIFY_SERVICE_SID`. `TWILIO_NUMBER` is not used.

the `fake` default only applies under an explicit `APP_ENV=development` (`backend/Makefile` and `docker-compose.yml` set it). any other environment — including unset — fails startup unless `OTP_PROVIDER=twilio` is fully configured; there is no fallback from a selected `twilio` provider to `fake`.

### app-review test numbers (issue #184)

apple app review needs to sign in without receiving a real sms — twilio verify can't reliably reach a reviewer-controlled number. `OTP_REVIEW_TEST_NUMBERS` (comma-separated e.164 numbers) and `OTP_REVIEW_TEST_CODE` (a single fixed code) configure a small allowlist that only applies with `OTP_PROVIDER=twilio`:

- for a listed number, `/v1/auth/otp/request` never calls twilio (no real sms, no cost, no dependency on twilio reachability), and `/v1/auth/otp/verify` accepts only the exact `OTP_REVIEW_TEST_CODE`.
- every other number is unaffected — real twilio verify, as always.

both variables must be set together or both left unset; a half-configured pair fails startup instead of silently doing nothing or turning into a global bypass, same as `OTP_PROVIDER`'s other settings. unset is the default and disables the feature entirely.

### production setup

set `APP_ENV=production`, `OTP_PROVIDER=twilio`, and the three twilio values as deployment secrets. `fake`, unset, and unknown providers are rejected at startup. to rotate the auth token, update the deployment secret and restart; to roll back, redeploy with the previous secret. during a twilio outage, logins fail with retryable internal errors while the rest of the api keeps working.

### local twilio smoke test

keep real values only in a repo-root `.env.local` (gitignored — copy [`.env.example`](.env.example)); never commit them or paste them into logs, issues, or pr evidence. backend secrets live here, not in `app/.env.local` — that file only carries flutter-side, non-secret local settings (maps key, provider selection — see [`app/.env.local.example`](app/.env.local.example)).

1. in the [twilio console](https://console.twilio.com), create or select a verify service (use the **live** account credentials, not the test ones — twilio verify rejects test credentials) and put its `VA...` sid in `.env.local` as `TWILIO_VERIFY_SERVICE_SID`, alongside `TWILIO_ACCOUNT_SID` and `TWILIO_AUTH_TOKEN`.
2. run the backend with the twilio provider, loading secrets without echoing them:

   ```text
   cd backend
   set -a; . ../.env.local; set +a
   OTP_PROVIDER=twilio make run
   ```

3. request a code from the flutter login flow (or the api directly), confirm a real sms arrives, verify the code, and complete login.
4. test a wrong code (rejected as invalid) and an expired code (rejected as expired).
5. unset one required value (e.g. `TWILIO_AUTH_TOKEN=""`) and confirm startup fails instead of falling back to the fake provider.
6. drop `OTP_PROVIDER=twilio` and confirm the deterministic fake flow still works for normal local development.

## firebase (push + analytics, issue #84)

one firebase project backs both integrations, each behind an app-owned abstraction:

- `NOTIFICATION_PROVIDER` — backend notifier **and** flutter app: `fake` (local default: log-only sender, opt-in sheet stays local ui) or `fcm` (real push via fcm http v1 + firebase messaging in the app).
- `ANALYTICS_PROVIDER` — flutter app only: `none` (local default: nothing leaves the device) or `firebase` (google analytics for firebase).

the local defaults need no firebase project at all. the backend's `fake` default only applies under an explicit `APP_ENV=development`; any other environment fails `cmd/notifier` startup unless `NOTIFICATION_PROVIDER=fcm` is fully configured — there is no fallback from a selected `fcm` to `fake` (same posture as `OTP_PROVIDER`).

### one-time firebase project setup

1. create the firebase project (a separate non-production project for local validation) and register the flutter targets: `dart pub global activate flutterfire_cli`, then `flutterfire configure` inside `app/` — this overwrites the placeholder `app/lib/firebase_options.dart` with committable public client configuration.
2. for the backend notifier, create a service account with the *firebase cloud messaging api* role and download its json key. keep the file outside the repository; only its path goes into the environment. legacy server keys are not supported.
3. for the web target, create a web push certificate (vapid key pair) in the firebase console's cloud messaging settings, and fill the real values into `app/web/firebase-messaging-sw.js` (background/terminated web push only; foreground web works without it).

secrets: the service-account json, its path in `.env.local`, and apns keys are secrets and never committed. `firebase_options.dart` and other flutterfire-generated platform config are public client configuration and are committable.

### backend variables (repo-root `.env.local`)

```text
NOTIFICATION_PROVIDER=fcm
FCM_CREDENTIALS_FILE=/absolute/path/to/firebase-service-account.json
```

### flutter variables (`app/.env.local`, forwarded by scripts/run_web.sh)

```text
ANALYTICS_PROVIDER=firebase
NOTIFICATION_PROVIDER=fcm
FCM_VAPID_KEY=... # web target only
```

for non-web targets, pass the same values as `--dart-define` flags to `flutter run`/`flutter build`.

### local push smoke test

1. `flutterfire configure` has been run and the app builds with the generated options.
2. run the api normally; run the notifier with the fcm provider:

   ```text
   cd backend
   set -a; . ../.env.local; set +a
   make run-notifier
   ```

3. in the app (built with `NOTIFICATION_PROVIDER=fcm`), sign in, follow a cat, and accept the opt-in sheet — permission is requested only there, never on first launch.
4. from a second account, create an active needs-help update for that cat; confirm the push arrives and opening it lands on the cat detail, with exactly one in-app notification record.
5. confirm misconfiguration fails closed: unset `FCM_CREDENTIALS_FILE` and check the notifier refuses to start.

### analytics validation

build with `ANALYTICS_PROVIDER=firebase` against the non-production project and use firebase DebugView (`--dart-define` builds on android need `adb shell setprop debug.firebase.analytics.app <package>`; web logs events with debug mode query param). verify the required events and parameters from [docs/product/analytics.md](docs/product/analytics.md) appear, and that no event ever carries names, free text, coordinates, tokens, or raw ids. local development and ci stay on `ANALYTICS_PROVIDER=none`, so production data streams only ever contain production builds.

### release targets (0.1)

- **web**: supported for foreground push and analytics out of the box; background/terminated web push additionally requires the configured `firebase-messaging-sw.js` and `FCM_VAPID_KEY`.
- **android**: 0.1 release target (product-owner decision 2026-07-29); publish timing is the product owner's. the Flutter Android target (`app/android`, package id `istanbul.tekir`, portrait-only, `minSdk` 24 / `targetSdk` 36) builds a signed, Play-ready `.aab` from this repo, with maps, push, and analytics all wired — see [android development](#android-development) for the full setup and play path. the machine-local prerequisites are an upload keystore (`android/key.properties`), an android maps sdk key (`android/maps.properties`), and the firebase android client config (`app/android/app/google-services.json`); none of the three is committed, and a clone without them still builds. console-side work is complete as of 2026-08-17: store listing, app content declarations (privacy policy, app access with the review test number, ads, content rating, target audience, data safety, advertising id), play app signing enrollment, and all four signing fingerprints on the maps key restriction. a signed bundle (`0.4.2`, versionCode 3) is on internal testing. because the developer account is **personal**, production access still needs 12 testers on a 14-day closed test.
- **ios**: 0.1 release target (product-owner decision 2026-07-29). the Flutter iOS target (`app/ios`, bundle id `istanbul.tekir`, min iOS 15) builds and has shipped through testflight; the app store submission is in review as of 2026-08-17. a fresh clone still needs its own `pod install` + Xcode build on a mac, registration of the `istanbul.tekir` iOS app in Firebase (`GoogleService-Info.plist` is not committed), and the APNs key for push before running or archiving locally. see [ios development](#ios-development) for the full setup and testflight path.

## object storage providers

`OBJECT_STORAGE_PROVIDER` selects where uploaded media (cat photos) is stored:

- `fake` (local default): deterministic, no network. objects are written to `MEDIA_LOCAL_DIR` (default `backend/data/media`) and served back by the api at `GET /v1/media/objects/{key}`; no object-storage account needed. this is what `make run`, docker compose, and the automated tests use.
- `s3`: real s3-compatible object storage (digitalocean spaces for 0.1). requires `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, and `S3_PUBLIC_BASE_URL`. `S3_FORCE_PATH_STYLE` is optional and stays `false` for spaces.

the `fake` default only applies under an explicit `APP_ENV=development`. any other environment — including unset — fails startup unless `OBJECT_STORAGE_PROVIDER=s3` is fully configured; there is no fallback from a selected `s3` provider to local disk (same posture as `OTP_PROVIDER` and `NOTIFICATION_PROVIDER`).

the variable names are application-owned (`S3_*`, not `AWS_*`) so the process can never accidentally pick up unrelated host credentials.

### production setup

set `APP_ENV=production`, `OBJECT_STORAGE_PROVIDER=s3`, and the six `S3_*` values as deployment secrets. `fake`, unset, unknown, and partially configured providers are rejected at startup. objects are uploaded with `x-amz-acl: public-read`, the validated image content type, and an immutable cache-control policy; `S3_PUBLIC_BASE_URL` (the bucket's public endpoint, or its cdn endpoint) is what stored media urls are built from — changing it later only affects new uploads, since urls are persisted per media row. uploads go through the backend api only, so no bucket cors configuration is needed.

operational procedures:

- **credential rotation**: create a second spaces access key, update the deployment secrets, restart, then revoke the old key. startup only validates presence, so a bad key surfaces as logged `s3 object storage rejected the configured credentials` on the first upload — verify with a real upload before revoking.
- **rollback**: redeploy with the previous secrets. rolling back from `s3` to `fake` is allowed only outside production; production never silently downgrades.
- **provider outage**: cat creation and media upload fail with retryable internal errors (one bounded retry per request for transient failures); reads are unaffected for already-delivered urls served by spaces/cdn, and the rest of the api keeps working.
- **orphan cleanup**: a failed database write compensates by deleting the just-uploaded object; if that best-effort delete also fails, the leaked object is logged (`failed to clean up media object after create failure`). to detect orphans, list bucket objects and compare against `media.object_key`; objects absent from the table and older than a day are safe to delete. never delete objects newer than that — an upload may be mid-transaction.
- **incident response**: if credentials leak, revoke the key in the digitalocean console first (writes fail closed, public reads continue), then rotate as above and audit the bucket for unexpected objects.

### local spaces smoke test

keep real values only in a repo-root `.env.local` (gitignored — copy [`.env.example`](.env.example)); never commit them or paste them into logs, issues, or pr evidence.

1. create a non-production space and a dedicated spaces access key in the digitalocean console, and fill the six `S3_*` values in `.env.local` (`S3_ENDPOINT` is the regional endpoint without the bucket name; `S3_PUBLIC_BASE_URL` is `https://<space>.<region>.digitaloceanspaces.com` or the cdn endpoint).
2. run the backend with the s3 provider, loading secrets without echoing them:

   ```text
   cd backend
   set -a; . ../.env.local; set +a
   OBJECT_STORAGE_PROVIDER=s3 make run
   ```

3. create a cat with a jpeg and a png through the real flutter flow; confirm the returned photo url points at `S3_PUBLIC_BASE_URL`, renders, and the object's content type and cache-control look right in the console.
4. restart the backend and confirm the cat still displays its photo.
5. retry the same create with the same idempotency key and confirm no duplicate cat or extra object appears.
6. unset one required value (e.g. `S3_SECRET_ACCESS_KEY=""`) and confirm startup fails instead of falling back to local disk.
7. drop `OBJECT_STORAGE_PROVIDER=s3` and confirm the local fake flow still works for normal development.

## content moderation providers (issue #241)

`MODERATION_PROVIDER` selects how pre-publication content moderation classifies user-submitted cat names, update/needs-help comments, photos, and videos before they are ever stored or published:

- `fake` (local default): deterministic, no network — `service.FakeModerator`. Ordinary test/dev content is always allowed; specific fixture inputs (see `backend/internal/service/moderation.go`'s `FakeModerationRejectMarker` and the magic image-dimension triggers in the same file) simulate a rejection or a provider failure for tests. This is what `make run`, docker compose, and the automated tests use — normal ci never calls a real model.
- `cloudflare`: real moderation via Cloudflare Workers AI (`service.CloudflareModerator`). Requires `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `MODERATION_TEXT_MODEL`, and `MODERATION_VISION_MODEL`. Model slugs are validated only for presence at startup — never resolved against a live model call (issue #241 explicitly rules that out for startup/readiness).

the `fake` default only applies under an explicit `APP_ENV=development`. any other environment — including unset — fails startup unless `MODERATION_PROVIDER=cloudflare` is fully configured; there is no fallback from a selected `cloudflare` provider to `fake` (same posture as `OTP_PROVIDER`/`OBJECT_STORAGE_PROVIDER`/`NOTIFICATION_PROVIDER`).

tekir owns the allow/reject policy: both models classify content, but only ever against the fixed, application-owned category vocabulary in `moderation.go`'s `moderationTextPrompt`/`moderationImagePrompt` — never a raw vendor taxonomy, and raw model prose is never a product contract. malformed or unparseable model output, a timeout, or a transport failure all fail closed identically (`service.ErrModerationUnavailable`) — nothing is ever stored or published on a moderation failure.

video moderation samples 3 deterministic frames (near start, middle, near end) via a real `ffmpeg` binary (`service.FFmpegFrameExtractor` — a runtime dependency baked into the backend container image, see `backend/Dockerfile`), composes them into one contact sheet in pure Go, and classifies that sheet through the same vision-model path as a photo — there is no separate video-specific model call.

### production setup

set `APP_ENV=production`, `MODERATION_PROVIDER=cloudflare`, and the four cloudflare values as deployment secrets (`CLOUDFLARE_API_TOKEN` is a secret; the model slugs are not). `fake`, unset, unknown, and partially configured providers are rejected at startup.

### image moderation is currently off in production

`MODERATION_VISION_MODEL` is deliberately unset in the production environment, which switches image moderation off: photos and videos publish unclassified while cat names, update comments and needs-help notes are still classified and still fail closed. The api logs this at startup so it can never be true silently.

The reason is that no Workers AI request shape found so far actually delivers an image to a model on this account. Verified against the live api:

| request | result |
| --- | --- |
| vision model, `image` as a `data:` uri | `200`, but the image is ignored — a 1x1 test image and a 2.5 MB photo return an identical answer and identical token counts |
| vision model, raw base64 string | `Engine Not Ready` |
| vision model, `image` as a byte array | `Type mismatch of '/image'` |
| vision model, public https url | `Internal server error` |
| text model (vision-capable), `image_url` content part, on `/ai/run` and on `/v1/chat/completions` | `200`, prompt tokens unchanged — the image is dropped |

Until one of those is resolved, an enabled image path would either reject every photo (the model answers from the prompt alone, and answered "reject/animal_cruelty" for every input tried) or pass everything while claiming to moderate. Both are worse than being explicitly off.

### cloudflare smoke suite (release gate)

normal ci runs only against the deterministic `fake` provider. before a release that ships or changes the `cloudflare` provider, run its separate, manually-triggered smoke suite against real cloudflare workers ai credentials to verify the configured model slugs, request schema, structured-result parsing, representative turkish text, a representative image input, and basic latency — this is a required release gate for 0.4, not an optional check. run it from `backend/`:

```text
CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=... make smoke-cloudflare
```

the suite lives in `backend/internal/service/cloudflare_moderator_smoke_test.go` behind the `cloudflare_smoke` build tag, so `go test ./...` and ci never reach it. it skips silently when the credentials are absent. `MODERATION_TEXT_MODEL`/`MODERATION_VISION_MODEL` override the models it exercises; without them it uses the deployment defaults. it covers turkish safe/unsafe text, a welfare report with a visible injury (which must stay allowed), an image call, and a contact-sheet-sized image, and logs each call's latency — latency is reported rather than asserted, since it sits inside the user's own publish request but a hard threshold would make the gate flaky.

## mobile runtime configuration validation (issue #131)

required mobile config fails in one of two deliberately different ways:

- **fails startup**: `API_BASE_URL` in release builds ([api base url](#api-base-url)) and the google maps ios sdk key (`app/ios/Runner/AppDelegate.swift`, see [google maps sdk (ios)](#google-maps-sdk-ios)) — both stop the app with a diagnostic naming the fix, instead of a native crash or a map that renders with no backend data.
- **degrades instead of blocking**: `ANALYTICS_PROVIDER`/`NOTIFICATION_PROVIDER` and firebase itself ([firebase](#firebase-push--analytics-issue-84)) — analytics/push must never block the product (issue #84). a missing/unrecognized value or a failed firebase init falls back to `none`/`fake` and logs a diagnostic instead of stopping startup: `Env.unrecognizedProviderWarnings()` (`app/lib/core/config/env.dart`) catches a typo'd provider value that would otherwise degrade silently, and `bootstrapFirebase()` (`app/lib/core/firebase/firebase_bootstrap.dart`) logs unconditionally — not only in debug builds — when firebase itself fails to come up.

`runStartupConfigDiagnostics()` (`app/lib/core/config/startup_validation.dart`) runs the non-fatal checks once, from `main()`, before any feature that reads them initializes.

the android maps sdk key follows the "degrades" side deliberately: android reads it from a manifest meta-data entry, so a missing key cannot be detected at startup the way the ios `GMSServices` call can — the map renders blank and the sdk logs an authorization failure. the check moves to build time instead: a release build with no key fails in gradle with a diagnostic naming the fix, so a keyless artifact can never reach play. see [google maps sdk (android)](#google-maps-sdk-android).

## flutter development

install flutter dependencies:

```text
cd app
flutter pub get
```

### google maps local key

copy the local environment template and set a development-only google maps javascript api key:

```text
cd app
cp .env.local.example .env.local
```

run the configured web target:

```text
cd app
./scripts/run_web.sh
```

`app/web/index.html` contains a placeholder. the run script substitutes the local key at runtime and restores the file when it exits. never commit a real key.

restrict the development key to the maps javascript api and the local origin used by the script. use a separate restricted production key with independent quota and billing controls.

### google maps sdk (ios)

`google_maps_flutter` is in `app/pubspec.yaml`, and CocoaPods pulls the native `GoogleMaps` sdk automatically. the sdk requires `GMSServices.provideAPIKey(...)` to run before any map view is created, or it terminates the process. `app/ios/Runner/AppDelegate.swift` calls this on startup, reading the key from the `GMSApiKey` entry in `Info.plist`, which is filled in at build time from an xcconfig variable. if the key is missing or still the placeholder, the app fails fast with a `fatalError` that names the fix instead of crashing with the native `GMSServicesException`.

supply a real key locally, once, before your first run:

```text
cd app/ios/Flutter
cp GoogleMaps.xcconfig.example GoogleMaps.xcconfig
```

edit `GoogleMaps.xcconfig` and set `GOOGLE_MAPS_API_KEY` to a development-only ios key. the file is gitignored — never commit a real key. restrict it to the ios sdk and the app's bundle id; use a separate restricted production key with independent quota and billing controls.

### api base url

the flutter client uses `http://localhost:8080` by default. override it when the api is exposed elsewhere:

```text
cd app
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8081
```

the `localhost` default only applies to debug/profile runs (issue #128). release builds (`flutter run --release`, `flutter build ...`) that don't get an explicit `API_BASE_URL` fail fast at startup with a `StateError` naming the fix, instead of launching normally with a map that renders but no backend data. the production value used for testing is `https://app.tekir.istanbul/api`:

```text
cd app
flutter build ios --release --dart-define=API_BASE_URL=https://app.tekir.istanbul/api
```

ios/android read the same default (`http://localhost:8080` in debug/profile) unless you pass the same `--dart-define` flag to `flutter run`/`flutter build ios`.

## ios development

a mac with Xcode is required for everything in this section — none of it works on linux/windows. this covers the path from a clean clone to a physical-device run and a testflight-ready build; see [firebase](#firebase-push--analytics-issue-84) above for the shared push/analytics setup this section builds on.

### ios-specific prerequisites

- a mac running a current Xcode, with the ios 15+ simulator/platform components installed.
- an [Apple Developer](https://developer.apple.com/account) account (free personal team works for physical-device development; a paid membership ($99/year) is required to submit to TestFlight/App Store).
- [CocoaPods](https://cocoapods.org) (`sudo gem install cocoapods`, or via `brew install cocoapods`).
- the flutter/dart versions from [prerequisites](#prerequisites) above, plus `flutter pub get` already run in `app/`.

### apple developer team and signing

the checked-in project (`app/ios/Runner.xcodeproj`) has no `DEVELOPMENT_TEAM` set and `CODE_SIGN_STYLE = Automatic` — signing is a per-contributor local setting, not something committed to the repo:

1. open `app/ios/Runner.xcworkspace` in Xcode (not the `.xcodeproj` — CocoaPods requires the workspace; see [pod install](#pod-install-and-opening-the-project) below).
2. select the **Runner** target → **Signing & Capabilities**.
3. under **Team**, pick your Apple Developer account (personal team is fine for device testing).
4. leave **Automatically manage signing** checked; Xcode provisions a development certificate and an ad-hoc provisioning profile for the bundle identifier below.

never commit a team id, provisioning profile, or signing certificate — these stay local/Xcode-managed.

### bundle identifier

the app ships as `istanbul.tekir` (`PRODUCT_BUNDLE_IDENTIFIER` in `project.pbxproj`, matching the Android `applicationId`). register this exact identifier under your Apple Developer account (**Certificates, Identifiers & Profiles → Identifiers**) before the first device run or archive — Xcode's automatic signing creates it for you the first time you build to a device, but App Store Connect requires it to exist as an App ID before you can create the app record for TestFlight.

if you need a personal scratch identifier instead (e.g. testing signing without registering the real one), change `PRODUCT_BUNDLE_IDENTIFIER` locally and never commit the change.

### google maps sdk (ios)

`google_maps_flutter` is in `app/pubspec.yaml`, and CocoaPods pulls the native `GoogleMaps` sdk automatically — but unlike the web target (see [google maps local key](#google-maps-local-key)), nothing in `app/ios` currently supplies an api key to it: `app/ios/Runner/AppDelegate.swift` does not call `GMSServices.provideAPIKey`. add it locally, once, before your first run:

```swift
import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GMSServices.provideAPIKey("YOUR_IOS_MAPS_KEY")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
```

use a development-only key restricted to the **iOS SDK** and this bundle identifier (`istanbul.tekir`) in the google cloud console — a separate key from the one used by `app/.env.local` for web. `AppDelegate.swift` is a tracked file: keep the real key as an uncommitted local change (`git diff` should show it before every commit), the same rule as never placing a real key in `app/web/index.html`.

### firebase (`GoogleService-Info.plist`)

the shared firebase project setup is in [firebase](#firebase-push--analytics-issue-84) above. for ios specifically:

1. run `flutterfire configure` from `app/` (as in the shared one-time setup) and select the **ios** platform when prompted, using the bundle id `istanbul.tekir`. this both updates `app/lib/firebase_options.dart` with a real ios entry (currently a placeholder that throws `UnsupportedError`) and downloads `GoogleService-Info.plist` into `app/ios/Runner/`.
2. in Xcode, confirm `GoogleService-Info.plist` shows up under the `Runner` group with **Target Membership** set to `Runner`; if `flutterfire configure` didn't add it to the project automatically, drag it in and check the box yourself.
3. `GoogleService-Info.plist` is not committed (matches the android/`google-services.json` posture — see [release targets](#release-targets-01)); `firebase_options.dart` is committable public client configuration, same as the web entry already in the repo.
4. push (`NOTIFICATION_PROVIDER=fcm`) additionally needs an APNs authentication key uploaded to the firebase project (**Project settings → Cloud Messaging → Apple app configuration**) — created once in the Apple Developer portal (**Keys**, "Apple Push Notifications service (APNs)").

### running on a physical iphone

```text
cd app
pod install --project-directory=ios
flutter run -d <device-id> --dart-define=API_BASE_URL=http://<your-mac-lan-ip>:8080
```

- `flutter devices` lists connected/paired devices and their `<device-id>`.
- the simulator can reach `localhost:8080` directly; a physical iphone cannot — it must reach the mac over the lan, so point `API_BASE_URL` at your mac's lan ip (not `localhost`) and start the backend with `docker compose up -d` first (see [local services](#local-services)).
- the phone must be unlocked and paired, with "trust this computer" accepted, and (first run only) the generated development certificate trusted on-device: **Settings → General → VPN & Device Management**.

#### pod install and opening the project

`flutter pub get` regenerates `ios/Flutter/Generated.xcconfig`; `pod install` (or the implicit one `flutter run`/`flutter build ios` triggers) reads it and updates `Runner.xcworkspace`. always open `Runner.xcworkspace`, never `Runner.xcodeproj` directly — the plain project has no pod targets linked and fails to build.

### recommended local config workflow

there's no `app/ios/.env.local` equivalent — ios config lives in two places, both untracked/local by convention:

- the maps api key: a local, uncommitted edit to `AppDelegate.swift` (above).
- `GoogleService-Info.plist`: downloaded by `flutterfire configure`, not committed.
- everything else (api base url, analytics/notification provider) goes through `--dart-define`, same flags as [firebase variables](#flutter-variables-appenvlocal-forwarded-by-scriptsrun_websh) and [api base url](#api-base-url) above, e.g.:

  ```text
  flutter run -d <device-id> \
    --dart-define=API_BASE_URL=http://<your-mac-lan-ip>:8080 \
    --dart-define=NOTIFICATION_PROVIDER=fcm \
    --dart-define=ANALYTICS_PROVIDER=firebase
  ```

### building an app store ipa

```text
cd app
flutter build ipa --release
```

this produces `build/ios/archive/Runner.xcarchive` and, if an export method resolves (automatic signing with a valid team does this by default), `build/ios/ipa/*.ipa`. if the export step fails, open the archive in Xcode's Organizer (`open build/ios/archive/Runner.xcarchive`) and use **Distribute App → TestFlight & App Store** to export/upload instead.

### build numbers for testflight

App Store Connect rejects a re-upload with a build number it has already seen for the same version. the build number is the `+N` suffix in `app/pubspec.yaml`'s `version:` (currently `1.0.0+1`, feeding `CURRENT_PROJECT_VERSION`/`FLUTTER_BUILD_NUMBER` in Xcode) — bump it before every new TestFlight upload:

```text
flutter build ipa --release --build-number=2
```

or edit `version: 1.0.0+2` in `app/pubspec.yaml` directly. the marketing version (`1.0.0`, before the `+`) only needs to change for a user-visible release, not every TestFlight build.

### uploading through transporter / app store connect

1. create the app record in [App Store Connect](https://appstoreconnect.apple.com) first (**My Apps → +**), using bundle id `istanbul.tekir` (already registered per [bundle identifier](#bundle-identifier) above) — the upload fails if the app record doesn't exist yet.
2. upload with either:
   - Xcode Organizer's **Distribute App → TestFlight & App Store** flow straight from the archive, or
   - the standalone [Transporter](https://apps.apple.com/app/transporter/id1450874784) app: point it at the `.ipa` from `flutter build ipa`.
3. wait for Apple's automated processing (usually a few minutes to an hour) before the build appears under **TestFlight** in App Store Connect.
4. add internal testers (immediate, no review) or external testers (requires a first-time beta app review).

### common ios failure modes

- **blank/gray map, no crash**: `GMSServices.provideAPIKey` was never called, or the key isn't restricted for the iOS SDK — see [google maps sdk (ios)](#google-maps-sdk-ios).
- **crash on launch mentioning `FirebaseApp` or `GoogleService-Info.plist`**: `flutterfire configure` wasn't run for the ios platform, or the plist wasn't added to the Runner target — see [firebase](#firebase-googleservice-infoplist) above. this only affects `NOTIFICATION_PROVIDER=fcm`/`ANALYTICS_PROVIDER=firebase` builds; the local defaults (`fake`/`none`) don't initialize firebase at all.
- **`Generated.xcconfig must exist` when running `pod install` manually**: run `flutter pub get` first (see [pod install and opening the project](#pod-install-and-opening-the-project)).
- **build fails / red signing errors in Xcode**: no team selected, or the bundle id isn't registered to your account yet — see [apple developer team and signing](#apple-developer-team-and-signing).
- **app installs but can't reach the api from a physical device**: `API_BASE_URL` pointed at `localhost` instead of the mac's lan ip, or the mac's firewall is blocking the incoming connection — see [running on a physical iphone](#running-on-a-physical-iphone).
- **App Store Connect rejects the upload with "already used a build number"**: bump `+N` in `app/pubspec.yaml` or pass `--build-number` — see [build numbers for testflight](#build-numbers-for-testflight).
- **push permission prompt never appears on device**: confirm the build used `--dart-define=NOTIFICATION_PROVIDER=fcm` — the local `fake` default keeps the opt-in sheet ui-only and never requests the real system permission (same behavior documented in [firebase](#firebase-push--analytics-issue-84) above).

## android development

this covers the path from a clean clone to a play-ready app bundle. unlike ios, all of it works on linux — no proprietary toolchain, no second machine. the shared push/analytics setup this builds on is in [firebase](#firebase-push--analytics-issue-84) above.

### android-specific prerequisites

- the android sdk with platform `android-36` and build-tools `36.0.0` (android studio installs these, or `sdkmanager` from the command-line tools)
- a jdk 17 on `PATH` with `JAVA_HOME` set — gradle and `keytool` both need it. with asdf: `asdf plugin add java && asdf install java temurin-17.0.20+8 && asdf set -u java temurin-17.0.20+8`
- `flutter doctor` must report the android toolchain as `[✓]` before anything below works

### upload keystore and `key.properties`

release builds are signed with an upload key that never leaves the machine. google re-signs every artifact with the play app signing key it holds, so the upload key is a credential for talking to play, not the key users' devices verify — losing it is recoverable through an upload-key reset in the play console.

create it once, outside the repository:

```text
keytool -genkeypair -v -keystore "$HOME/tekir-upload.jks" -storetype PKCS12 \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload \
  -dname "CN=tekir, O=tekir, L=Istanbul, ST=Istanbul, C=TR"
```

then point `app/android/key.properties` at it (copy `key.properties.example`). the file and every `*.jks`/`*.keystore` are gitignored; store the password in a password manager and back the keystore up somewhere that is not this machine.

when `key.properties` is absent, release builds fall back to the debug key so a fresh clone can still run `flutter run --release` locally — such a build is not uploadable to play.

print the upload key's fingerprints when a service needs them (the maps key restriction below does):

```text
keytool -list -v -keystore "$HOME/tekir-upload.jks" -alias upload
```

### google maps sdk (android)

`google_maps_flutter` reads the key from a `com.google.android.geo.API_KEY` manifest meta-data entry. the value is a manifest placeholder filled in from `app/android/maps.properties` (gitignored, copy `maps.properties.example`):

```text
cd app/android
cp maps.properties.example maps.properties
```

debug and profile builds work without the file — the map renders blank. release builds fail in gradle with a message naming the fix, so no keyless bundle reaches play.

restrict the key in the google cloud console to the **maps sdk for android** api and to the app: package name `istanbul.tekir` plus **every** signing certificate sha-1 fingerprint. a key restricted to the upload fingerprint alone works in a local release build and fails in every play-distributed install, which is the single easiest way to ship a blank map to real users.

the app is enrolled in play's **quantum-ready hybrid signing**, so google holds three keys, not one: a classical rsa 4096 key for pre-android-17 devices, plus a second classical key and an ml-dsa-65 post-quantum key that sign together for android 17+ (apk signature scheme v3.2). play's own guidance is to register all three with every api provider. download them from **play console → app signing → app signing key certificate** (`certificates.zip`, containing `deployment_cert.der`, `hybrid_classical_cert.der`, `hybrid_pqc_cert.der`) and read each fingerprint with:

```text
keytool -printcert -file deployment_cert.der
```

so the maps key ends up with four android entries for `istanbul.tekir`: the three play fingerprints and the local upload key's. note that hybrid signing is not compatible with apk signature scheme v4, so play-as-you-download optimization is off for this app.

use a separate restricted production key from the development one, with its own quota and billing controls.

### firebase (`google-services.json`)

register the android app in the firebase project and generate its client config from `app/`:

```text
~/.pub-cache/bin/flutterfire configure --project=<project-id> \
  --platforms=android --android-package-name=istanbul.tekir
```

this writes `app/android/app/google-services.json` and fills in the android entry of `app/lib/firebase_options.dart` (previously a placeholder that threw `UnsupportedError`). as on ios, the platform config file is not committed and `firebase_options.dart` is — it is public client configuration.

the `com.google.gms.google-services` gradle plugin is declared in `app/android/settings.gradle.kts` but applied by `app/android/app/build.gradle.kts` **only when `google-services.json` exists**, so a clone without the file still builds. fcm on android needs no signing fingerprint, unlike ios which needs an apns key.

### building the play app bundle

```text
cd app
flutter build appbundle \
  --dart-define=API_BASE_URL=https://app.tekir.istanbul/api \
  --dart-define=NOTIFICATION_PROVIDER=fcm \
  --dart-define=ANALYTICS_PROVIDER=firebase
```

the artifact is `build/app/outputs/bundle/release/app-release.aab`. verify it is signed by the upload key, not the debug key, before uploading:

```text
jarsigner -verify -verbose:summary -certs build/app/outputs/bundle/release/app-release.aab
```

the `--dart-define` flags are the same ones documented in [api base url](#api-base-url) and [flutter variables](#flutter-variables-appenvlocal-forwarded-by-scriptsrun_websh). a release build with no `API_BASE_URL` fails at startup by design (issue #128); the provider flags default to `fake`/`none`, which silently ships an app with no push and no analytics — pass them explicitly for anything that goes to play.

### version codes for play

play rejects an upload whose version code it has already seen, and requires each new release to have a strictly higher one. the version code is the `+N` suffix in `app/pubspec.yaml`'s `version:`, shared with the ios build number — bump it before every upload, including replacements within the same testing track:

```text
flutter build appbundle --build-number=4 ...
```

### play console path

the app is `istanbul.tekir`, tr-TR only for 0.1. store assets and the approved copy live in `assets/store/` (`listing/listing.md` is the source of truth). console order:

1. **create app** — name `tekir`, default language tr-TR, app, free (free → paid cannot be changed later)
2. **app integrity → play app signing** — enrolled by default for new apps; the keystore above is the upload key
3. **store listing** — 512×512 icon (`assets/app-icon/android/play-icon-512.png`), 1024×500 feature graphic (`assets/store/listing/play-feature-graphic.png`), screenshots from `assets/store/screenshots/`
4. **app content** — privacy policy `https://tekir.istanbul/privacy`, account deletion `https://tekir.istanbul/privacy#account-deletion` (`privacy.html` redirects there, so use the canonical path), data safety (phone number, display name, precise location, photos, fcm token), content rating questionnaire, target audience, ads: none
5. **internal testing** — up to 100 testers, no review wait; use it to verify the real signed artifact
6. **closed testing → production**

a **personal** developer account created after november 13, 2023 cannot reach production without running a closed test with at least 12 testers opted in continuously for 14 days, followed by a production access application. plan the release around that window and start the closed test on a build whose map and push already work. organization accounts are exempt but require d-u-n-s verification.

### common android failure modes

- **blank/gray map, no crash, `Authorization failure` in logcat**: the maps key is missing, not restricted to the maps sdk for android, or restricted to a fingerprint that isn't the one that signed this install — see [google maps sdk (android)](#google-maps-sdk-android). a map that works locally and fails from play is almost always the missing play app signing fingerprint.
- **gradle fails with "Google Maps Android API key is missing"**: intended — a release build without `android/maps.properties`.
- **`No Java Development Kit (JDK) found` from `flutter doctor`**: see [android-specific prerequisites](#android-specific-prerequisites).
- **play rejects the bundle as debug-signed**: `android/key.properties` is missing or points at a path that doesn't exist, so the build fell back to the debug key — verify with `jarsigner` before every upload.
- **play rejects the version code**: bump `+N` in `app/pubspec.yaml` — see [version codes for play](#version-codes-for-play).
- **push or analytics dead on android only**: the build didn't get `--dart-define=NOTIFICATION_PROVIDER=fcm`/`ANALYTICS_PROVIDER=firebase`, or `google-services.json` was absent at build time so the google-services plugin never applied. firebase failing to initialize degrades instead of crashing (issue #84), so this is silent — check the `bootstrapFirebase()` diagnostic in logcat.

## production deployment

production is a single digitalocean droplet plus managed postgres, with the stack in `/opt/tekir`: `docker-compose.production.yml`, `.env.production`, a `Caddyfile`, and the service-account secret. caddy terminates tls, strips `/api/*` to the api container, and serves everything else from the web container. the droplet host, credentials, and every value in `.env.production` live outside this repository.

there is no ci deployment pipeline. images are built on a maintainer's machine, shipped as tarballs, and switched by tag — each service is versioned and deployed independently, so **the running versions routinely differ from each other and from `main`**. check what is actually deployed before assuming:

```text
curl -s https://app.tekir.istanbul/version.json     # the flutter web bundle
ssh <droplet> 'docker ps --format "{{.Image}}"'     # api, notifier, web, caddy
```

### shipping a new web bundle

```text
cd app
flutter build web --release \
  --dart-define=API_BASE_URL=/api \
  --dart-define=NOTIFICATION_PROVIDER=fcm \
  --dart-define=ANALYTICS_PROVIDER=firebase \
  --dart-define=FCM_VAPID_KEY=...
```

`API_BASE_URL=/api` keeps the client same-origin behind caddy, so no cors configuration is involved; it is compile-time, so changing it means rebuilding. then substitute the production web maps key into **`build/web/index.html`** — the build output, never `app/web/index.html`, which must keep its `__GOOGLE_MAPS_API_KEY__` placeholder — and build, ship, and switch the image:

```text
docker build -t tekir-web:<version> -f Dockerfile.web .
docker save tekir-web:<version> | gzip -1 > tekir-web-<version>.tar.gz
scp tekir-web-<version>.tar.gz <droplet>:/opt/tekir/
ssh <droplet> 'docker load -i /opt/tekir/tekir-web-<version>.tar.gz'
```

on the droplet, bump the `tekir-web` tag in `docker-compose.production.yml` and recreate only that service. **always pass `--env-file .env.production`** — the file is not named `.env`, so without the flag compose resolves every variable to a blank string:

```text
docker compose --env-file .env.production -f docker-compose.production.yml up -d web
```

recreating `web` that way is harmless because the web container reads none of those variables, but recreating `api`/`notifier` without the flag makes them fail startup by design ([mobile runtime configuration validation](#mobile-runtime-configuration-validation-issue-131) covers the same fail-closed posture on the client). rollback is the reverse tag switch plus another `up -d` — the previous image stays on the droplet.

the api and notifier follow the same tarball flow from `backend/Dockerfile` and `backend/Dockerfile.notifier`. migrations are not baked into the images: run goose from a maintainer machine against the managed database before starting an api version that needs them.

## validation

run backend validation:

```text
cd backend
make fmt
make build
make test
make lint
```

run flutter validation:

```text
cd app
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

validate migrations against a clean local database when a change affects schema or persistence:

```text
docker compose down -v
docker compose up -d postgres
cd backend
make migrate-up
make migrate-status
```

## ci behavior

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs the repository validation on pushes and pull requests. reproduce a failing job with the matching commands above before changing workflow configuration.

backend ci covers build, vet, lint, formatting, migrations, and tests against postgres/postgis. flutter ci covers formatting, analysis, and tests.

## troubleshooting

### postgres or api port is already in use

set `POSTGRES_PORT` or `API_PORT` when starting docker compose. when changing the postgres host port, also pass a matching `DATABASE_URL` to backend commands.

### api is not ready

```text
docker compose ps
docker compose logs postgres
docker compose logs api
curl -v http://localhost:8080/readyz
```

confirm postgres is healthy before debugging application code.

### migrations fail after local schema changes

inspect status first:

```text
cd backend
make migrate-status
```

for disposable local data, recreate the docker volume and apply migrations again. do not use destructive reset steps against shared or production databases.

### flutter map is blank

confirm `.env.local` exists, the api key is enabled for the maps javascript api, and its browser restrictions include the local origin. run through `./scripts/run_web.sh`; do not place the key permanently in `app/web/index.html`. if the run script is killed hard, it can leave the substituted key in that file — check `git diff app/web/index.html` before committing.

on android the equivalent cause is a missing or wrongly restricted native key — see [common android failure modes](#common-android-failure-modes).

### flutter cannot reach the api

check the api health endpoint, the selected host port, and the `API_BASE_URL` override. browser requests must target an address reachable from the browser, not the docker-internal service name.
