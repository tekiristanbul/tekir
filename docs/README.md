# docs

the project's written contracts. code is the implementation; these files are what
it is supposed to be, and why.

a document is either **authoritative** — binding on the implementation — or
**historical**, kept for the record and never a source of truth. `docs/design/`
mixes both and marks each file explicitly; the convention is defined in
[`design/implementation-contract.md`](design/implementation-contract.md).

## where to look

| directory | contains | approval owner |
| --- | --- | --- |
| [`product/`](product/) | what tekir does and why — the product contract | the product owner |
| [`architecture/`](architecture/) | technical contracts: api surface, schema, backend operations, client architecture, standards in use | the code maintainer |
| [`adr/`](adr/) | why durable decisions were made, and what was rejected | the code maintainer |
| [`design/`](design/) | approved visual and interaction references, plus superseded drafts marked as historical | the product owner |
| [`releases/`](releases/) | one file per release: what shipped, when, and whether it is published | the code maintainer |
| [`brand.md`](brand.md) | canonical product, domain, and repository naming | the product owner |

## the ones to read first

- [`product/vision.md`](product/vision.md) — what tekir is, in one sentence.
- [`product/principles.md`](product/principles.md) — the boundaries that do not move.
- [`architecture/api.md`](architecture/api.md) — the http surface.
- [`architecture/db.md`](architecture/db.md) — the schema.
- [`architecture/standards.md`](architecture/standards.md) — the open standards the codebase implements, and the gaps.
- [`adr/README.md`](adr/README.md) — the decision records, and when to write one.

## related, outside this directory

- [`../GOVERNANCE.md`](../GOVERNANCE.md) — who decides what, and where each kind of decision is recorded.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — how a change gets made and accepted.
- [`../DEVELOPMENT.md`](../DEVELOPMENT.md) — how to run, build, validate, and deploy everything.
- [`../AGENTS.md`](../AGENTS.md) — the delivery contract automated agents work under.

## conventions

- lowercase prose, turkish only in user-facing copy quoted as a contract.
- each topic document is one file with `## goal` and `## decisions`; a topic gets
  a file, a decision does not.
- durable decisions with real alternatives get an adr in [`adr/`](adr/).
  everything else is a line under `## decisions`. the threshold is in
  [`../GOVERNANCE.md`](../GOVERNANCE.md).
- `[[name]]` links a sibling topic document.
- a superseded document is not deleted. it is marked historical, in place.
