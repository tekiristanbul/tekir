# 0001. server-issued device and account identity

- status: accepted
- date: 2026-08-19
- source: issue #58, issue #65, issue #80; `docs/architecture/api.md` (identity /
  auth model), `docs/architecture/backend.md` (auth / security)
- supersedes: —

## context

tekir's trust model ([`docs/product/trust.md`](../product/trust.md)) is two-tier:
reading the map requires no account, but following a cat and every contribution
require a phone-verified account. that split needs two different things from
identity. an app installation has to be addressable for push delivery and for
carrying a guest's follows into an account once the person signs in. a
contribution has to be attributable to a verified person.

collapsing both onto one credential would either force an account before anyone
can receive a push, or let an installation identifier authorize writes.

## decision

identity is server-issued and split across two headers.

- `POST /v1/devices` accepts only `{ push_token?, platform }`. the server
  generates `device_id` and a high-entropy `device_token` and stores only the
  token's sha-256 hash. later device-scoped requests send
  `X-Device-Token: <device_token>`. the device credential identifies an app
  installation for follows, push delivery, and account linking. it never
  authorizes a contribution write.
- an account is obtained by phone otp verification. verification returns a
  short-lived hs256 jwt sent as `Authorization: Bearer`, plus an opaque,
  hashed, revocable refresh token that exchanges for new access tokens without
  repeating otp.
- following a cat, ordinary and needs-help updates, media uploads, and new-cat
  creation all require the bearer token (issue #65 moved follows and ordinary
  updates onto this model; the rest were bearer-required from the start).
- otp verification links the calling device to exactly one account, idempotently.
  linking a device already linked to a different account is rejected with `409`
  rather than silently reassigned.

## alternatives considered

- **a client-generated device identifier.** rejected: anything the client can
  choose or copy can be replayed, so it is not identity on its own.
- **one credential for both device and account.** rejected: device association
  and contribution authorization are different authorities and were kept in
  separate headers so neither can stand in for the other.
- **silently reassigning a device to a second account on login.** rejected in
  issue #80: it would retroactively re-attribute the device's earlier authored
  content to an account that did not write it.

## consequences

- the backend holds a single shared hmac signing key (`JWT_SIGNING_KEY`).
  rotating it invalidates every outstanding access token at once, and there is
  no jwks, `kid`, or asymmetric verification path to hand a second service a
  verification key without sharing the signing secret.
- every write path has to check two different credentials, and clients have to
  handle a stale device token separately from a wrong otp code — the flutter
  client distinguishes them by response body text, not status, since both are
  `401`.
- guest-era follows survive login only because linking explicitly backfills
  them; the backfill columns are write-once from `null`, so a later relink can
  never claim them.
- issue #80's unlink-on-logout is what keeps a shared installation usable by a
  second account. without it, a linked device could never sign into a different
  account.
