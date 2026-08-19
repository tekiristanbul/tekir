---
applyTo: "docs/**/*.md,README.md,CONTRIBUTING.md,GOVERNANCE.md,MAINTAINERS.md,SUPPORT.md,CHANGELOG.md"
---

# documentation

- distinguish planned, pending, and implemented behavior explicitly.
- when a decision changes, update or remove contradictory older statements in the same change.
- keep shared contracts consistent across product, api, database, backend, flutter, worker, and design documentation.
- do not add speculative architecture or describe unimplemented features as available.
- never present pending product owner approval as final.
- keep canonical product naming as `tekir` and the domain as `tekir.istanbul`.
- an accepted adr in `docs/adr/` is not rewritten. a changed decision is a new adr, and the old one's status becomes `superseded by NNNN`.
- when a topic document's `## decisions` section gains a durable decision with real alternatives, the rationale belongs in an adr and the topic document links to it.
