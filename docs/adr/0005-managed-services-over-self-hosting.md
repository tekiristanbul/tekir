# 0005. managed services over a self-hosted platform

- status: accepted
- date: 2026-08-19
- source: `docs/architecture/backend.md` (goal, data layer, deployment, out of
  scope)
- supersedes: —

## context

tekir is built and operated by one unfunded maintainer.
[`docs/architecture/backend.md`](../architecture/backend.md) states the
constraint plainly: the deployment minimizes operational ownership rather than
maximizing infrastructure sophistication.

## decision

the project buys operational ownership rather than running it.

- **postgres is managed** (digitalocean managed postgresql). backups, failover,
  and version upgrades are the provider's responsibility, not the project's.
- **media storage is an object store behind the s3 api**, not a self-run one,
  and application code depends on the s3 api rather than a provider sdk so the
  provider stays replaceable.
- **no kubernetes**, and no gateway api, cert-manager, self-hosted postgres
  operator, or cluster lifecycle platform. reconsidered only if sponsorship or
  external funding provides both a reason and a budget to own that complexity —
  traffic growth alone is not that reason.
- **no microservices and no external message broker.** the notification worker
  is a second binary out of the same repository polling a database table.
- every vendor sits behind an application-owned interface (`SmsSender`,
  `ObjectStore`, `NotificationSender`, `Moderator`), each environment-gated and
  fail-closed, so a provider swap is an adapter, not a rewrite.

## alternatives considered

- **kubernetes for the api and worker.** rejected in
  `docs/architecture/backend.md`: it adds platform complexity the project has no
  budget or person to own, and mvp traffic does not require it.
- **self-hosted postgres.** rejected: backups, failover, and upgrades are
  exactly the operational ownership this decision exists to avoid.
- **a provider-specific storage sdk.** rejected: depending on the s3 api instead
  keeps digitalocean spaces replaceable by any s3-compatible endpoint.

## consequences

- the project is exposed to provider pricing and provider outages, with no
  in-house fallback for either.
- the platform skills the maintainer already has are deliberately unused here.
  reintroducing them later is a new decision, not a natural next step.
- because nothing is self-hosted, there is also no platform automation to
  inherit: the current deployment is manual, single-host, and has no cd
  pipeline. that is the state this decision leaves the project in, not a
  decision in its own right — the topology and the shipping procedure are
  recorded in [`docs/architecture/backend.md`](../architecture/backend.md) and
  `DEVELOPMENT.md` ("production deployment"), and either may change without a
  new adr. automating deployment, or moving to a container platform, would be a
  new decision.
- multi-region and disaster recovery stay out of scope, as
  `docs/architecture/backend.md` already states.
