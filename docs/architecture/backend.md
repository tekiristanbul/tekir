# backend

## goal

define how [[api]] and [[db]] get deployed and operated, for a solo, currently-unfunded founder — so the initial deployment should minimize operational ownership, not maximize infrastructure sophistication. no azure, per an earlier explicit constraint, but "no azure" and "kubernetes from day one" are not the same requirement, and this draft previously conflated them.

## decisions

### service shape (single service, no microservices)

- **api service** (go: handler → service → repository, interfaces, testable): serves every endpoint in [[api]], stateless, scales horizontally. ships as a single container image — that's what keeps the door open to kubernetes later without committing to it now.
- **notification worker**: same repo, separate binary/process, polling the `notification_outbox` table (see [[db]]) and dispatching fcm pushes to followers. a full message broker (kafka/rabbitmq) is unwarranted at this scale.

### data layer — managed, not self-hosted

at ~1,000 cats and one operator, running a database is a cost, not a capability. self-hosting postgres (even via an operator like cloudnativepg) means owning failover, backups, and upgrades personally — real ongoing toil with no upside until traffic or a team justifies it.

- **postgres + postgis**: a managed postgres service (not azure; aws rds, digitalocean managed databases, or any provider with a postgis-capable managed offering). backups and failover are the provider's job.
- **media storage**: code is written against the **s3 api** (aws sdk or `minio-go`), not a specific vendor sdk, so the actual bucket — aws s3, digitalocean spaces, cloudflare r2 — is swappable without touching the application. a **managed** bucket, not self-hosted minio, for the same reason as the database.

### deployment

- the api and worker are two container images; they can run on a single small vm, a managed container platform (e.g. a "run a container" service from whichever provider is chosen), or a kubernetes cluster — the code doesn't care. **don't stand up a kubernetes cluster, gateway api, or cert-manager for this yet.** revisit that once traffic or a team makes the operational cost worth it — the container images are what make that migration a redeploy, not a rewrite, when the time comes.
- ci/cd: **github actions** (not azure devops) — the repo is expected to live on github regardless, given the sponsorship route.
- scale: mvp traffic (the ~1,000-cats success signal from [[vision]]) is comfortably served by one instance of each process; no autoscaling or replica planning needed yet.

### auth / security

- short-lived jwt `access_token` + a hashed, revocable `refresh_token` after otp verification (see [[db]] and [[api]]) — the `access_token` alone is never enough for the client to stay logged in across app restarts.
- device identity is a **server-issued** token, not a client-generated id — see the auth model in [[api]]. this is what makes anonymous follow/update actions safe to allow without login.
- **sms otp provider is not chosen** — a real vendor/cost decision (deliverability in turkey matters), not an architectural one. the backend hides it behind an `SmsSender` interface so the choice doesn't touch the rest of the service.

### observability

structured logging + basic prometheus metrics (request rate/latency, worker queue depth). distributed tracing is unnecessary complexity at this stage.

## open questions

- which managed postgres provider (aws rds / digitalocean managed databases / other, not azure) — depends on github sponsors funding, the user's call.
- which managed s3-compatible storage provider (aws s3 / digitalocean spaces / cloudflare r2) — same dependency.
- where the containers actually run (single vm vs. a managed container platform) — a cost/ops-effort call once a provider is picked, not an architectural one.
- sms otp provider.
- when kubernetes adoption is actually justified — not now, deliberately.

## out of scope

- kubernetes, gateway api, cert-manager, cnpg, or any self-hosted operator — deliberately deferred, not forgotten. the container images are the bridge to this later.
- multi-region / disaster-recovery design.
- azure anything — explicitly ruled out for this project.
