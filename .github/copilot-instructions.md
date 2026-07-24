# tekir repository context

tekir (`tekir.istanbul`) is a map-first application for istanbul street cats. it is not a social network. every change should help answer: where is this cat, what is its latest status, and how can someone help?

## source of truth

1. the assigned issue and the latest explicit issue comments
2. `docs/product/` for user behavior and data contracts
3. `docs/architecture/` for api, database, backend, and flutter boundaries
4. `docs/design/` and an applicable `prototype/` screen for approved visual hierarchy and interaction baseline
5. the existing implementation and tests

follow `AGENTS.md` for readiness, delivery, review, evidence, and definition-of-done rules. do not resolve conflicts between sources by guessing.

## repository architecture

- `backend/`: go api, service and repository code, postgres/postgis migrations, sqlc queries, seed command, and tests
- `app/`: flutter web application using the repository's existing navigation, state management, design tokens, and google maps integration
- `docs/product/`: accepted product behavior and durable product decisions
- `docs/architecture/`: technical contracts and durable architectural decisions
- `docs/design/`: design contracts and reviewed screenshots
- `prototype/`: interaction and visual baseline when the relevant screen exists

## ownership

- the product owner owns user scope, ux, visual direction, and user-facing copy.
- the technical founder owns architecture, api contracts, data model, security, infrastructure, and code quality.
- product owner approval is never implied by implementation, tests, a draft pr, technical review, or an agent confidence score.
- agents report findings and evidence; they never approve or merge.

## agent responsibilities

- implementation must stay within accepted issue scope, validate affected paths, update durable documentation, and open one draft pr.
- technical review must prioritize correctness, data safety, migration safety, compatibility, security, privacy, performance, tests, documentation, and scope control. it must report blocking findings, non-blocking findings, open questions, residual risks, and confidence by area.
- product review must evaluate only user behavior, turkish copy, visual output, edge states, acceptance criteria, and approved design references. it must not invent technical architecture or approve on behalf of the human product owner.
- when review confidence is below 80% in any material area, recommend human technical review explicitly.

## engineering constraints

- keep changes minimal, deterministic, testable, and secure.
- use existing frameworks, services, runtime dependencies, state management, navigation, and design tokens unless the issue explicitly requires a change.
- never commit secrets, tokens, api keys, generated credentials, or real user data.
- do not expose raw technical data to users.
- do not represent out-of-scope actions as enabled, disabled, mocked, or fake ui.
- keep all user-facing text in turkish and all github technical communication in english.