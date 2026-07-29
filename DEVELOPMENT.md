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
- **android**: 0.1 release target (product-owner decision 2026-07-29); publish timing is the product owner's. the Flutter Android target exists (`app/android`, package id `istanbul.tekir`, portrait-only) with generated launcher/adaptive icons and a prototype-aligned native launch screen, and builds from this repo. `flutter build appbundle` produces the Play-ready artifact once `android/key.properties` points at an upload keystore (see `android/key.properties.example`); without it, release builds fall back to debug signing for local runs. still console-side: play listing + data-safety form, play app signing, firebase android app registration if push/analytics ship enabled, real-build screenshots.
- **ios**: 0.1 release target (product-owner decision 2026-07-29). the Flutter iOS target exists (`app/ios`, bundle id `istanbul.tekir`, min iOS 15) with generated icons and a prototype-aligned native launch screen, but it was scaffolded from linux and has never been built: before treating it as release-ready, run `pod install` + a real Xcode build on a mac, register the `istanbul.tekir` iOS app in Firebase (`GoogleService-Info.plist` is not committed), and configure the APNs key for push.

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

### api base url

the flutter client uses `http://localhost:8080` by default. override it when the api is exposed elsewhere:

```text
cd app
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8081
```

only the web target is currently configured.

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

confirm `.env.local` exists, the api key is enabled for the maps javascript api, and its browser restrictions include the local origin. run through `./scripts/run_web.sh`; do not place the key permanently in `app/web/index.html`.

### flutter cannot reach the api

check the api health endpoint, the selected host port, and the `API_BASE_URL` override. browser requests must target an address reachable from the browser, not the docker-internal service name.
