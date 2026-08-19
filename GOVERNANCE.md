# governance

tekir is a small open source project with two people holding decision authority:
a code maintainer and a product owner. this document says who decides what, how a
decision gets recorded, and when a change needs more than a github issue. it
exists so those answers are readable without asking.

it is deliberately light. there is no steering committee, no voting, and no
proposal process beyond what is written here.

## roles

- **code maintainer** — owns architecture, api contracts, the data model,
  security, infrastructure, code quality, issue creation, release sequencing,
  and every merge. named in [`MAINTAINERS.md`](MAINTAINERS.md).
- **product owner** — owns user scope, ux, visual direction, and user-facing
  turkish copy, and approves any change to them. named in
  [`MAINTAINERS.md`](MAINTAINERS.md). product owner approval is never implied by
  an implementation, a passing test suite, a draft pull request, a technical
  review, or an agent.
- **contributor** — anyone reporting a bug, joining a discussion, or
  implementing an acknowledged issue. see [`CONTRIBUTING.md`](CONTRIBUTING.md).
- **agent** — an automated implementation or review agent working under
  [`AGENTS.md`](AGENTS.md). agents implement and review. they never approve and
  never merge.

no role can approve its own work. every change reaches `main` through a pull
request a human merged, and a change to user-visible behavior, copy, or visual
output records product owner approval before that happens.

## where decisions live

| kind of decision | recorded in |
| --- | --- |
| what the product does and why | [`docs/product/`](docs/product/) |
| technical contracts and boundaries | [`docs/architecture/`](docs/architecture/) |
| approved visual and interaction references | [`docs/design/`](docs/design/) |
| why a durable decision was made, and what was rejected | [`docs/adr/`](docs/adr/) |
| scope and acceptance criteria of one change | the github issue |
| what shipped, when | [`docs/releases/`](docs/releases/) and [`CHANGELOG.md`](CHANGELOG.md) |

when sources disagree, the order of authority is: the latest explicit product
owner comment, then the issue body and later maintainer comments, then product
docs, then architecture docs, then design references, then the existing
implementation. this is the same order [`AGENTS.md`](AGENTS.md) binds agents to.

a missing decision is never invented. it is asked as one precise question on the
issue, and implementation stops until it is answered.

## how a change flows

```text
github issue          default. every change starts here.
   ↓
discussion            only when the problem is open-ended and has no accepted
                      scope yet — an idea, a direction, community input.
   ↓
adr                   only for a durable decision with real alternatives.
   ↓
implementation → pull request → human review → merge
   ↓
docs/releases/ entry when it ships
```

### issue, discussion, or adr

**a github issue** is the default and covers almost everything: bugs, features,
refactors, chores, follow-ups. an issue defines one concrete problem, its
accepted scope, and testable acceptance criteria. if you can state what "done"
means, it is an issue.

**a discussion** comes first only when the problem is not yet shaped: an idea
with no accepted scope, a question of direction, or something that needs other
people's input before anyone can write acceptance criteria. discussions are not
support, not a feature-request queue, and not a commitment. see
[`.github/DISCUSSIONS.md`](.github/DISCUSSIONS.md).

**an adr** is written only when a decision is durable, expensive to reverse, and
had real alternatives:

- persistent data model semantics
- public api contracts and compatibility boundaries
- authentication and authorization boundaries
- component and service boundaries
- technology choices the project would have to migrate off
- deployment topology and operational ownership

an adr is not a proposal and does not gate anything: it is written alongside the
change that makes the decision, in the same pull request, and merges with it.
everything below that bar is a line in the relevant topic document's
`## decisions` section, or nothing. format, numbering, and status vocabulary are
in [`docs/adr/README.md`](docs/adr/README.md).

there is no rfc process. the issue is the proposal.

## how a decision is approved

- **technical decisions** — the code maintainer decides, on the issue or in
  review. durable ones get an adr; the rest get a `## decisions` line.
- **product decisions** — the product owner decides. a pull request that changes
  approved user-visible behavior, copy, or visual output records product owner
  approval before it is merged. documentation maintenance that only synchronizes
  an already accepted decision does not need it.
- **security decisions** — handled privately per [`SECURITY.md`](SECURITY.md)
  until a fix ships, then recorded like any other change.
- **release decisions** — the code maintainer decides what ships and when. each
  release gets a file in [`docs/releases/`](docs/releases/) stating what it
  contains and whether it is published.

## availability

one person holds each role, so each is a single point of failure for what it
owns. while the code maintainer is unavailable nothing merges and nothing
deploys — production deployment requires a maintainer machine and credentials
that are not in this repository
([adr-0005](docs/adr/0005-single-droplet-deployment-without-cd.md)). while the
product owner is unavailable, work that does not change user-visible behavior
still proceeds; work that does waits for approval rather than assuming it.

issues and discussions stay open in the meantime. this is a known limitation,
stated rather than papered over. adding anyone to either role is recorded here
and in [`MAINTAINERS.md`](MAINTAINERS.md).

## conduct

participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
enforcement is the responsibility of the maintainers in
[`MAINTAINERS.md`](MAINTAINERS.md).
