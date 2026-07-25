# backend

## goal

define how [[api]] and [[db]] get deployed and operated, for a solo, currently-unfunded founder — so the initial deployment should minimize operational ownership, not maximize infrastructure sophistication. no azure, per an earlier explicit constraint, but "no azure" and "kubernetes from day one" are not the same requirement, and this draft previously conflated them.

## decisions

### service shape (single service, no microservices)

- **api service** (go: handler → service → repository, interfaces, testable): serves every endpoint in [[api]], stateless, scales horizontally. ships as a single container image — that's what keeps the door open to kubernetes later without committing to it now.
- **notification worker**: same repo, separate binary/process, polling the `notification_outbox` table (see [[db]]) and dispatching fcm pushes to followers. a full message broker is unwarranted at this scale. delivery is at-most-once for mvp.

### data layer — managed, not self-hosted

at ~1,000 cats and one operator, running a database is a cost, not a capability.

- **postgres + postgis**: a managed postgres service, not azure.
- **media storage**: code targets the s3 api so the managed bucket provider remains replaceable.

### deployment

- the api and worker ship as container images and can run on a small vm, managed container platform, or later kubernetes. do not introduce kubernetes, gateway api, or cert-manager yet.
- ci/cd uses github actions.
- one instance of each process is sufficient for the mvp success scale.

### auth / security

- short-lived jwt `access_token` plus a hashed, revocable `refresh_token` after otp verification.
- every content-producing contribution requires a phone-verified bearer identity: ordinary updates, needs-help updates, media uploads, and new-cat creation.
- device identity remains a server-issued token for installation association, push delivery, device-owned follows, and linking a device to an authenticated account. it is not sufficient authorization for contribution writes.
- **sms otp provider is not chosen** — the backend hides it behind an `SmsSender` interface.

### observability

structured logging plus basic prometheus metrics. distributed tracing is unnecessary at this stage.

## open questions

- which managed postgres provider (aws rds / digitalocean managed databases / other, not azure).
- which managed s3-compatible storage provider (aws s3 / digitalocean spaces / cloudflare r2).
- where the containers run (single vm vs. managed container platform).
- sms otp provider.
- when kubernetes adoption is justified — deliberately not now.

## out of scope

- kubernetes, gateway api, cert-manager, cnpg, or any self-hosted operator.
- multi-region / disaster-recovery design.
- azure anything.
