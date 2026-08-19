# agent delivery contract

## workflow roles

- `tekir implementation` implements one accepted issue and opens one draft pull request.
- `tekir technical review` performs the first correctness, architecture, migration, compatibility, security, privacy, test, and documentation review.
- `tekir product review` checks user behavior, turkish copy, visual output, edge states, acceptance criteria, and approved design references.
- agents never approve or merge pull requests. human maintainers own final decisions.
- during the bootstrap phase, the technical founder uses chatgpt to spot-check technical-review findings and improves repository instructions when gaps are found.

## definition of ready

before assigning implementation, the issue must define:

- the concrete problem and accepted scope
- testable acceptance criteria
- relevant product and technical decisions
- dependencies and explicit exclusions
- design references when user-visible behavior changes
- whether product owner approval is required
- unresolved decisions marked clearly; the implementation agent must not invent answers

## before implementation

- read the assigned issue and every existing comment before changing files.
- follow linked issues, pull requests, product docs, architecture docs, and design references needed to understand the accepted scope.
- start from the current `main` branch and use one branch and one draft pull request for the issue.
- preserve existing user changes. do not overwrite unrelated work.
- publish a short implementation plan before editing.

## source of truth and decisions

- issue-specific decisions follow this order: the latest explicit product owner comment, the issue body and later maintainer comments, product docs, architecture docs, applicable `docs/design/` references, then existing implementation.
- when sources conflict or a product or architecture decision is missing, stop implementation and ask one precise question on the issue. do not invent a decision.
- product docs define behavior and data contracts. architecture docs define technical boundaries. `docs/design/` references and the existing shipped implementation define visual hierarchy and interaction baseline, not new behavior.
- when an issue or review establishes a durable product or technical rule, update the relevant product or architecture document. create an adr only for consequential decisions with meaningful alternatives and long-term tradeoffs.
- an adr is a numbered file in `docs/adr/`, copied from `docs/adr/0000-template.md` and added to that directory's index. it is written in the same pull request as the change that makes the decision, and the topic document it governs links to it. the threshold and the issue/discussion/adr boundary are in `GOVERNANCE.md`.
- distinguish unresolved decisions from follow-up implementation work. do not describe planned behavior as implemented.

## scope

- implement only the assigned issue and its accepted comments.
- do not add speculative abstractions, frameworks, services, runtime dependencies, fake data, disabled controls, or unrelated cleanup.
- do not reinterpret the current design with generic material defaults.
- all user-facing copy is turkish. github technical comments, commit messages, and pull request descriptions are english.
- never add `co-authored-by` trailers or commit secrets, tokens, api keys, credentials, or real user data.

## risk and evidence

- classify changed behavior as low, medium, or high risk in the pull request.
- treat migrations, authentication, authorization, precise location, media handling, destructive operations, breaking api changes, notifications, and user data as high-risk areas.
- for migrations and api changes, verify existing-data safety, failure behavior, compatibility, and rollback or recovery expectations.
- for location, media, account, and reporting flows, review privacy, abuse, exposure, retention, and rate-limit implications.
- user-visible changes require screenshots or a short demo covering the main state and applicable loading, empty, error, and not-found states.

## definition of done

- acceptance criteria are satisfied without expanding scope.
- affected tests and repository validation commands pass, and exact commands and results are reported truthfully.
- code, product docs, architecture docs, api/database contracts, and migrations agree where applicable.
- discovered out-of-scope work is recorded as a follow-up instead of hidden in the current change.
- technical-review blocking findings are resolved.
- product owner approval is recorded when required.
- the pull request remains draft until required human review is complete.

## validation and delivery

- add or update tests for changed behavior and keep regression coverage intact.
- run the repository's real validation commands for every affected area. never report an unrun or failed check as successful.
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) is the canonical automated verification surface. it runs on every pull request and on `main` in three independent jobs — `backend`, `flutter`, and `docs` — and each check is its own step, so a failure names the area it came from.
- local commands are developer feedback and the evidence a pull request carries. they never substitute for ci: a passing local run, an agent's judgement, or a review claim does not override a failed ci check, and an agent never reports a change as validated while ci is red.
- open a draft pull request. do not mark it ready, approve it, or assume product owner approval.
- let the pull request closing keyword close the issue on merge; do not close issues manually.
- the pull request description must include closing keywords, implementation summary, important schema/api decisions, risk level, validations run, intentional exclusions, product owner review status, and screenshots or demo evidence for user-visible changes.
- address review feedback only when it is explicit, actionable, and within scope. ask on the issue when feedback requires a new product decision.