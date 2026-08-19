# architecture decision records

an adr records a durable decision: what was decided, why, what was rejected, and
what the project now has to live with. the topic documents in
[`docs/architecture/`](../architecture/) and [`docs/product/`](../product/) state
what is true *now*; an adr states why it became true and what the alternative
would have cost.

## when to write one

write an adr only when a decision is durable, expensive to reverse, and had real
alternatives. in practice that means:

- persistent data model semantics
- public api contracts and compatibility boundaries
- authentication and authorization boundaries
- component and service boundaries
- technology choices the project would have to migrate off
- deployment topology and operational ownership

everything else is a line in the relevant topic document's `## decisions`
section, or nothing at all. routine implementation choices do not get an adr.
see [`GOVERNANCE.md`](../../GOVERNANCE.md) for the full issue / discussion / adr
boundary.

## format

- one file per decision: `NNNN-short-title.md`, four-digit sequential id.
- copy [`0000-template.md`](0000-template.md).
- an accepted adr is not rewritten. if the decision changes, write a new adr and
  set the old one's status to `superseded by NNNN`.
- status vocabulary: `accepted`, `superseded by NNNN`, `rejected`.
- link the adr from the `## decisions` section of the topic document it governs.

## index

| id | title | status | date |
| --- | --- | --- | --- |
| [0001](0001-server-issued-device-and-account-identity.md) | server-issued device and account identity | accepted | 2026-08-19 |
| [0002](0002-postgis-geography-as-the-location-primitive.md) | postgis `geography(point, 4326)` as the location primitive | accepted | 2026-08-19 |
| [0003](0003-updates-as-an-append-only-history.md) | updates as an append-only history with keyset pagination | accepted | 2026-08-19 |
| [0004](0004-forward-only-immutable-migrations.md) | forward-only immutable migrations | accepted | 2026-08-19 |
| [0005](0005-managed-services-over-self-hosting.md) | managed services over a self-hosted platform | accepted | 2026-08-19 |

these five records were written after the fact, in issue #271, from decisions the
project had already made and documented in prose. they carry the date they were
written, and each names the issue and document the decision actually came from.
earlier decisions that are already adequately recorded in their topic documents
were deliberately left there rather than back-filled.
