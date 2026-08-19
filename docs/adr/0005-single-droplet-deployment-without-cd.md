# 0005. single droplet deployment without a cd pipeline

- status: accepted
- date: 2026-08-19
- source: `DEVELOPMENT.md` ("production deployment"),
  `docker-compose.production.yml`, `Caddyfile`,
  `docs/architecture/backend.md` (deployment)
- supersedes: the digitalocean app platform deployment sketched in
  `docs/architecture/backend.md` before this record

## context

tekir is built and operated by one unfunded maintainer.
[`docs/architecture/backend.md`](../architecture/backend.md) states the goal
plainly: the deployment minimizes operational ownership rather than maximizing
infrastructure sophistication.

the original sketch was digitalocean app platform with github actions as the
ci/cd system. what actually shipped, and what has run production since
2026-07-30, is different — and the documents disagreed with production until
this record was written.

## decision

production is one digitalocean droplet plus digitalocean managed postgres.

- the stack lives in `/opt/tekir` on the droplet: `docker-compose.production.yml`,
  `.env.production`, a `Caddyfile`, and the service-account secret. the droplet
  host, its credentials, and every value in `.env.production` are outside this
  repository.
- caddy terminates tls, routes `/api/*` to the api container, and serves
  everything else from the web container. the flutter web client is built with
  `API_BASE_URL=/api`, so it is same-origin and no cors configuration is
  involved in production.
- four containers: `api`, `notifier`, `web`, `caddy`.
- **there is no cd pipeline.** images are built on a maintainer's machine,
  shipped as tarballs over `scp`, `docker load`ed, and switched by bumping the
  image tag in the droplet's compose file. rollback is the reverse tag switch;
  the previous image stays on the droplet.
- each service is versioned and deployed independently, so running versions
  routinely differ from each other and from `main`.
- migrations are not baked into images. goose runs from a maintainer machine
  against the managed database before an api version that needs them starts —
  which is what [adr-0004](0004-forward-only-immutable-migrations.md) depends on.
- ci (`.github/workflows/ci.yml`) gates format, lint, build, migrations, and
  tests. it does not build, publish, or deploy anything.
- managed postgres means backups, failover, and upgrades are the provider's
  responsibility, not the project's.

## alternatives considered

- **kubernetes.** rejected in `docs/architecture/backend.md` and revisited only
  if sponsorship or external funding provides a reason and a budget to own the
  platform complexity. traffic growth alone is not that reason.
- **self-hosted postgres.** rejected: backups, failover, and upgrades are exactly
  the operational ownership this decision exists to avoid.

## consequences

- deployment requires a maintainer's machine and ssh access. nobody else can
  ship, and there is no deployment audit trail beyond the release notes in
  [`docs/releases/`](../releases/).
- "what is deployed" is not derivable from the repository. it has to be read
  from `https://app.tekir.istanbul/version.json` and
  `docker ps` on the droplet. `docker-compose.production.yml` in this repository
  is a template pinned at `0.1.0` tags; the droplet's copy is the live one.
- `docker compose` on the droplet must always be given `--env-file .env.production`.
  the file is not named `.env`, so without the flag every variable resolves to
  an empty string — `api` and `notifier` fail startup by design, but the
  mistake is silent for `web`.
- a single droplet is a single point of failure with no multi-region or
  disaster-recovery story, which `docs/architecture/backend.md` already places
  out of scope.
- moving to any automated pipeline later is a fresh decision and a new adr, not
  an extension of this one.
