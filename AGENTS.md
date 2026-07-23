# agent delivery contract

## before implementation

- read the assigned issue and every comment before changing files.
- follow linked issues, pull requests, product docs, architecture docs, and design references needed to understand the accepted scope.
- start from the current `main` branch and use one branch and one draft pull request for the issue.
- preserve existing user changes. do not overwrite unrelated work.
- publish a short implementation plan before editing.

## source of truth and decisions

- issue-specific decisions follow this order: the latest explicit product owner comment, the issue body and later maintainer comments, product docs, architecture docs, the relevant `prototype/` screen, then existing implementation.
- when sources conflict or a product or architecture decision is missing, stop implementation and ask one precise question on the issue. do not invent a decision.
- product docs define behavior and data contracts. architecture docs define technical boundaries. an applicable prototype defines visual hierarchy and interaction baseline, not new behavior.
- do not document planned behavior as implemented.

## scope

- implement only the assigned issue and its accepted comments.
- do not add speculative abstractions, frameworks, services, runtime dependencies, fake data, disabled controls, or unrelated cleanup.
- do not reinterpret the current design with generic material defaults.
- all user-facing copy is turkish. github technical comments, commit messages, and pull request descriptions are english.
- never add `co-authored-by` trailers or commit secrets, tokens, or api keys.

## validation and delivery

- add or update tests for changed behavior and keep regression coverage intact.
- run the repository's real validation commands for every affected area. never report an unrun or failed check as successful.
- open a draft pull request. do not mark it ready, approve it, or assume product owner approval.
- let the pull request closing keyword close the issue on merge; do not close issues manually.
- the pull request description must include closing keywords, implementation summary, important schema/api decisions, validations run, intentional exclusions, product owner review status, and screenshots for user-visible changes.
- address review feedback only when it is explicit, actionable, and within scope. ask on the issue when feedback requires a new product decision.
