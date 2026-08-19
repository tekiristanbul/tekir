# tekir repository context

tekir (`tekir.istanbul`) is a map-first application for istanbul street cats. it is not a social network. every change should help answer: where is this cat, what is its latest status, and how can someone help?

this file carries repository context only. the rules an agent works under are not repeated here; they live in the documents below and are read from there.

## canonical contracts

- [`AGENTS.md`](../AGENTS.md) — the delivery contract: definition of ready, scope, source-of-truth order, risk and evidence, definition of done, validation, and pull request contents.
- [`GOVERNANCE.md`](../GOVERNANCE.md) — who decides and who approves what, and where a decision is recorded.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — branch, commit, and per-area validation commands.
- [`.github/workflows/ci.yml`](workflows/ci.yml) — the canonical automated verification gate.

do not resolve a conflict between sources by guessing. `AGENTS.md` states the order of authority and requires one precise question on the issue instead.

## repository architecture

- `backend/`: go api, service and repository code, postgres/postgis migrations, sqlc queries, seed command, and tests
- `app/`: flutter application using the repository's existing navigation, state management, design tokens, and google maps integration
- `docs/product/`: accepted product behavior and durable product decisions
- `docs/architecture/`: technical contracts and durable architectural decisions
- `docs/design/`: design contracts and reviewed screenshots
- `docs/adr/`: architecture decision records — why a durable decision was made and what was rejected; `GOVERNANCE.md` carries the threshold for writing one

path-scoped technical guidance for go, flutter, migrations, tests, and documentation lives in [`.github/instructions/`](instructions/) and applies automatically to the files it names.

## agent surfaces

- `.claude/skills/` — the task workflows used in day-to-day development: `analyze-issue`, `implement-issue`, `review-pr`.
- [`.github/agents/tekir-product-review.agent.md`](agents/tekir-product-review.agent.md) — first-pass product review of a pull request.

no agent surface restates repository policy; each references the canonical contracts above.
