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
- otp delivery is hidden behind an `SmsSender` interface (implemented — issue #58) so the domain model never couples to one vendor. twilio remains the selected sms provider for mvp, but only a deterministic, no-network, log-only `FakeSmsSender` is wired as of issue #58 — selected via `OTP_PROVIDER` (`fake` is the only implemented value; the server fails to start on any other value rather than silently falling back). a real `TwilioSmsSender` is future work, gated on having a live twilio account to test against.
- media storage is hidden behind an `ObjectStore` interface (implemented — issue #70), mirroring `SmsSender`/`OTP_PROVIDER` exactly: digitalocean spaces (s3-compatible) remains the selected mvp provider (see "data layer" above), but only a deterministic, local-disk `FakeObjectStore` is wired as of issue #70 — selected via `OBJECT_STORAGE_PROVIDER` (`fake` is the only implemented value; the server fails to start on any other value). `MEDIA_LOCAL_DIR` sets where the fake provider reads/writes; `MEDIA_MAX_BYTES` bounds an uploaded file's size before it's ever decoded. unlike `FakeSmsSender`, the fake object store isn't purely a test double — the api also exposes `GET /v1/media/objects/{key}` ([[api]]) so it can actually serve back what it wrote, letting a local manual walkthrough view an uploaded photo without a real object-storage account. a real s3-compatible implementation is future work, gated the same way `TwilioSmsSender` is.
- push delivery is hidden behind a `NotificationSender` interface (implemented — issue #78), mirroring `SmsSender`/`ObjectStore`: only a deterministic, no-network, log-only `FakeNotificationSender` is wired, selected via `NOTIFICATION_PROVIDER` (`fake` is the only implemented value). unlike `OTP_PROVIDER`/`OBJECT_STORAGE_PROVIDER`, this has **no default** — an unset value fails `cmd/notifier`'s startup just as loudly as an unrecognized one, so a production deployment that forgot to configure it fails closed instead of silently running the dev/test provider. a real fcm-backed sender is future work, gated on registering a real push provider — out of scope for #78.
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
