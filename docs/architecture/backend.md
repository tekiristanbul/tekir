# backend

## goal

define how [[api]] and [[db]] get deployed and operated for a solo, currently-unfunded founder. the initial deployment minimizes operational ownership rather than maximizing infrastructure sophistication.

## decisions

### service shape

- **api service**: go handler → service → repository, shipped as one stateless container image.
- **notification worker**: same repository, separate binary/process polling `notification_outbox` and dispatching fcm pushes.
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

- short-lived jwt `access_token` plus a hashed, revocable `refresh_token` after otp verification.
- twilio is the selected sms otp provider for mvp, hidden behind an `SmsSender` interface.
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
