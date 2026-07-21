# backend

## goal

define how [[api]] and [[db]] get deployed and operated, for a solo founder whose server costs depend on funding (github sponsors) that isn't secured yet — so the stack has to be kubernetes-native and cloud-agnostic, not tied to a specific provider's managed services.

## decisions

### service shape (single service, no microservices)

- **api service** (go: handler → service → repository, interfaces, testable): serves every endpoint in [[api]], stateless, scales horizontally.
- **notification worker**: same repo, separate deployment/binary. polls an outbox-style `pending_notifications` queue and dispatches fcm pushes to followers. a full message broker (kafka/rabbitmq) is unwarranted at this scale — the outbox + a polling worker is enough, and simpler to run alone.

### data layer — self-hosted, kubernetes-native

no azure. no vendor-managed service is assumed, so the same manifests work on any cncf-conformant cluster.

- **postgres + postgis**: `cloudnativepg` (cnpg) operator, in-cluster. one primary + 1-2 replicas, `pgbackrest` backups to an s3-compatible target.
- **media storage**: code is written against the **s3 api** (aws sdk or `minio-go`), not a specific vendor sdk. the actual bucket — aws s3, digitalocean spaces, cloudflare r2, or an in-cluster minio — is swappable without touching the application.

### deployment

- target: any cncf-conformant cluster — aws eks, digitalocean doks, or a self-managed k3s box on a cheap vps. the point of going kubernetes-native is that switching clusters is a storageclass/ingressclass-level change, not an architecture change.
- **gateway api** + **cert-manager** for routing/tls — already cloud-agnostic.
- one helm chart, `values.yaml` carries image tag, replica count, and secret references (db connection string, s3 credentials, fcm key, sms provider key), sourced from k8s secrets (or `external-secrets` against whatever secret store the eventual cloud offers).
- ci/cd: **github actions** (not azure devops) — the repo is expected to live on github regardless, given the sponsorship route.
- scale: mvp traffic (the ~1,000-cats success signal from [[vision]]) is comfortably served by 2 api replicas + 1 worker; no hpa needed yet.

### auth / security

- short-lived jwt access token + refresh token after otp verification — standard, no further design needed here.
- **sms otp provider is not chosen** — a real vendor/cost decision (deliverability in turkey matters), not an architectural one. the backend hides it behind an `SmsSender` interface so the choice doesn't touch the rest of the service.

### observability

structured logging + basic prometheus metrics (request rate/latency, worker queue depth). distributed tracing is unnecessary complexity at this stage.

## open questions

- which cluster/cloud (aws eks / digitalocean doks / self-managed k3s) — depends on github sponsors funding, the user's call.
- which s3-compatible storage provider (aws s3 / digitalocean spaces / cloudflare r2 / self-hosted minio) — same dependency.
- sms otp provider.

## out of scope

- multi-region / disaster-recovery design.
- azure anything — explicitly ruled out for this project.
