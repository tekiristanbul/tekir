# tekir repository context

tekir (`tekir.istanbul`) is a map-first application for istanbul street cats. it is not a social network. every change should help answer: where is this cat, what is its latest status, and how can someone help?

## source of truth

1. the assigned issue and the latest explicit issue comments
2. `docs/product/` for user behavior and data contracts
3. `docs/architecture/` for api, database, backend, and flutter boundaries
4. `docs/design/` and the existing shipped implementation for approved visual hierarchy and interaction baseline
5. the existing implementation and tests

follow `AGENTS.md` for readiness, delivery, review, evidence, and definition-of-done rules. do not resolve conflicts between sources by guessing.

## repository architecture

- `backend/`: go api, service and repository code, postgres/postgis migrations, sqlc queries, seed command, and tests
- `app/`: flutter web application using the repository's existing navigation, state management, design tokens, and google maps integration
- `docs/product/`: accepted product behavior and durable product decisions
- `docs/architecture/`: technical contracts and durable architectural decisions
- `docs/design/`: design contracts and reviewed screenshots
- `docs/adr/`: architecture decision records — why a durable decision was made and what was rejected; `GOVERNANCE.md` carries the threshold for writing one

## ownership

- the product owner owns user scope, ux, visual direction, and user-facing copy.
- the technical founder owns architecture, api contracts, data model, security, infrastructure, and code quality.
- product owner approval is never implied by implementation, tests, a draft pr, technical review, or an agent confidence score.
- agents report findings and evidence; they never approve or merge.
- documentation maintenance that only synchronizes already accepted decisions does not require product owner review.
- changes to user behavior, user-facing turkish copy, visual output, ux interaction, or an explicitly pending product decision require human product owner review.
- required review must be derived from the actual diff semantics and repository ownership rules; do not use generic conditional disclaimers such as `if required` when the repository context is sufficient to decide.

## agent responsibilities

- implementation must stay within accepted issue scope, validate affected paths, update durable documentation, and open one draft pr.
- technical review must prioritize correctness, data safety, migration safety, compatibility, security, privacy, performance, tests, documentation, and scope control. for changed product or architecture concepts, it must perform a cross-document semantic-consistency pass across the applicable source-of-truth documents rather than reviewing changed files in isolation. it must report blocking findings, non-blocking findings, open questions, residual risks, required human review, evidence, and confidence by area.
- product review must evaluate only user behavior, turkish copy, visual output, edge states, acceptance criteria, and approved design references. it must not invent technical architecture or approve on behalf of the human product owner.
- when review confidence is below 80% in any material area, recommend human technical review explicitly.

## engineering constraints

- keep changes minimal, deterministic, testable, and secure.
- use existing frameworks, services, runtime dependencies, state management, navigation, and design tokens unless the issue explicitly requires a change.
- never commit secrets, tokens, api keys, generated credentials, or real user data.
- do not expose raw technical data to users.
- do not represent out-of-scope actions as enabled, disabled, mocked, or fake ui.
- keep all user-facing text in turkish and all github technical communication in english.