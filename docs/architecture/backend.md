# backend

## goal

define how [[api]] and [[db]] get deployed and operated for a solo, currently-unfunded founder. the initial deployment minimizes operational ownership rather than maximizing infrastructure sophistication.

## decisions

### service shape

- **api service**: go handler → service → repository, shipped as one stateless container image.
- **notification worker** (implemented — issue #78, `cmd/notifier`): same repository, separate binary/process polling `notification_outbox` and dispatching pushes for needs-help updates only. fcm remains the eventual mvp-selected push vendor, but no real provider is wired yet — see "auth / security" below.
- no microservices or external message broker are required for mvp.

### data layer

- **postgres + postgis**: digitalocean managed postgresql.
- **media storage**: digitalocean spaces through the s3-compatible api. application code depends on the s3 api rather than a digitalocean-specific storage sdk.
- backups, failover, and database upgrades are managed by digitalocean rather than self-hosted by the project.

### deployment

- api and notification worker deploy to digitalocean app platform as separate components built from their container definitions.
- github actions is the ci/cd system.
- mvp traffic is expected to run without kubernetes.
- kubernetes migration is reconsidered only after sponsorship or external funding provides a reason and budget to own the additional platform complexity. traffic growth alone may still be handled first by app platform scaling.
- no gateway api, cert-manager, self-hosted postgres operator, or cluster lifecycle platform is part of mvp.

### auth / security

- short-lived jwt `access_token` plus a hashed, revocable `refresh_token` after otp verification (implemented — issue #58).
- otp is provider-neutral behind two boundaries (implemented — issues #58/#59), selected via `OTP_PROVIDER`: `fake` keeps the deterministic, no-network, log-only local flow (`SmsSender` + backend-generated codes in `otp_codes`), and `twilio` routes both code delivery and code checking through twilio verify (`OTPVerificationProvider` / `TwilioVerifier`) — verify owns generation, delivery, expiry, resend cadence, and guess limiting end to end, so none of the local `otp_codes` machinery runs on that path. selection is environment-gated and fail-closed: `fake` (including the unset-provider default) is only reachable under an explicit `APP_ENV=development`; every other environment — `production`, unset, or unrecognized — accepts only `twilio` and fails startup on `fake`, unset, unknown, or a `twilio` selection missing any of `TWILIO_ACCOUNT_SID`/`TWILIO_AUTH_TOKEN`/`TWILIO_VERIFY_SERVICE_SID`. there is deliberately no runtime fallback from a selected `twilio` provider to `fake`, ever. twilio verify addresses a verify service sid, not a sender number — `TWILIO_NUMBER` is unused. the adapter maps every twilio outcome onto the existing auth error contract (invalid phone, invalid code, expired/replayed, throttled, and — for timeouts, outages, or runtime credential rejection — the same generic internal error any dependency outage produces), retries at most once and only for known-safe transient failures (a 5xx response or a dial error; never a timeout, which may already have sent an sms), propagates request cancellation to the outbound call, and never logs phone numbers, codes, sids, tokens, or raw response bodies. operational notes: rotating the auth token is a deployment-secret change plus restart (startup only validates presence, so a bad value surfaces as logged `401` mapping to internal errors — watch for `twilio verify rejected the configured credentials`); rollback is redeploying with the previous secret; a twilio outage degrades logins to retryable internal errors without touching the rest of the api.
- media storage is hidden behind an `ObjectStore` interface (implemented — issue #70), mirroring `SmsSender`/`OTP_PROVIDER` exactly: digitalocean spaces (s3-compatible) remains the selected mvp provider (see "data layer" above), but only a deterministic, local-disk `FakeObjectStore` is wired as of issue #70 — selected via `OBJECT_STORAGE_PROVIDER` (`fake` is the only implemented value; the server fails to start on any other value). `MEDIA_LOCAL_DIR` sets where the fake provider reads/writes; `MEDIA_MAX_BYTES` bounds an uploaded file's size before it's ever decoded. unlike `FakeSmsSender`, the fake object store isn't purely a test double — the api also exposes `GET /v1/media/objects/{key}` ([[api]]) so it can actually serve back what it wrote, letting a local manual walkthrough view an uploaded photo without a real object-storage account. a real s3-compatible implementation is future work, gated the same way `TwilioSmsSender` is.
- push delivery is hidden behind a `NotificationSender` interface (implemented — issues #78/#84), mirroring `SmsSender`/`ObjectStore`, selected via `NOTIFICATION_PROVIDER`: `fake` keeps the deterministic, no-network, log-only dev/test sender, and `fcm` sends real pushes through firebase cloud messaging http v1 (`FCMNotificationSender`) authenticated with a service-account json referenced by `FCM_CREDENTIALS_FILE` (the firebase project id comes from the file's `project_id`; legacy server keys are deliberately unsupported). selection is environment-gated and fail-closed exactly like `OTP_PROVIDER` (`config.ResolveNotificationProvider`): `fake` — including the unset-provider default — is only reachable under an explicit `APP_ENV=development`; every other environment accepts only a fully configured `fcm` and fails `cmd/notifier`'s startup on anything else, with no runtime fallback to `fake`, ever. the sender classifies fcm outcomes: a permanently rejected registration token (unregistered/invalid/sender-id mismatch) retires that device's `push_token` (token-matched, so a concurrently refreshed token survives) while the in-app `notifications` row — created unconditionally for every recipient device, token or not — remains the source of truth; transient failures (5xx, 429, timeouts) are retried at most once and only when known-safe (5xx or dial error, never a timeout), then logged and skipped under the outbox's existing at-most-once policy. clients register/refresh their fcm token via device-authenticated `PUT /v1/devices/me`, which updates the caller's own row in place and clears the same token off any other row, so a re-registered installation can never be pushed twice. nothing sensitive is ever logged or exposed: no registration tokens, credentials, message ids, or recipient lists.
- provider credentials are deployment secrets and never committed to the repository.
- device identity is used for installation association, push delivery, and account linking; contribution authorization follows [[api]] and [[trust]].

### observability

- structured logging and basic prometheus-compatible metrics for request rate, latency, failures, and worker queue depth.
- distributed tracing is not required for mvp.

## open questions

- none for mvp. concrete digitalocean plan sizes, region, retention settings, and twilio pricing configuration are deployment-time configuration rather than product or architecture questions.

## out of scope

- kubernetes, gateway api, cert-manager, cnpg, or any self-hosted operator.
- multi-region or disaster-recovery design.
- azure services.
- replacing twilio unless cost, deliverability, or regulatory evidence requires a new provider decision.
