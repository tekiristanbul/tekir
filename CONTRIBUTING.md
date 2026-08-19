# contributing

tekir is in early development. maintainers control product scope, architecture, issue creation, and release sequencing. [`GOVERNANCE.md`](GOVERNANCE.md) says who decides what and how a decision is recorded; [`MAINTAINERS.md`](MAINTAINERS.md) names the maintainer.

## how work actually flows

most changes here are maintainer-authored end to end, and that is worth stating plainly rather than describing a process nobody is running:

1. a maintainer opens an issue with accepted scope and testable acceptance criteria, using the implementation issue form.
2. the work is implemented by the maintainer or by an automated agent working under [`AGENTS.md`](AGENTS.md).
3. a pull request links the issue, carries validation output and evidence, and stays draft while review or approval is pending.
4. a human maintainer reviews, approves, and merges. agents never approve and never merge.

external contribution runs through the `help wanted` path below. it is open, and it is genuinely how an outside contribution gets accepted — it is simply not the path most changes take today.

## where to participate

- report reproducible bugs through the bug report issue form.
- share high-level product or community ideas in github discussions.
- share prototypes, concepts, and experiments in the Show & Tell discussion category.
- use issues for concrete feature requests and maintainer-prepared implementation work.
- implement code or documentation only from an open issue labeled `help wanted`.
- report vulnerabilities privately according to [`SECURITY.md`](SECURITY.md).

discussions are intentionally small and are not a support forum. ideas posted there are welcome for conversation, but they are not commitments and may not be accepted or scheduled.

## help wanted workflow

1. choose an open issue explicitly labeled `help wanted`.
2. comment on the issue before starting.
3. wait for a maintainer to acknowledge that you may take it.
4. implement only the accepted scope and follow the linked product, architecture, and design references.
5. open a pull request linked to the issue and include the required validation and evidence.

unsolicited pull requests, feature implementations, product changes, and ux redesigns are not accepted. maintainers may close them without review.

## bug reports

bug reports are accepted while the project is in early development. provide a minimal reproduction, expected and actual behavior, environment details, and logs or screenshots with secrets and personal data removed.

use discussions rather than issues for:

- high-level product or community ideas
- early visual or ux concepts
- prototypes and experiments

use maintainer-created issues for concrete feature requests, approved product work, and implementation tasks. tekir does not use discussions for support, troubleshooting, or general conversation.

## ownership boundaries

- product decisions live in `docs/product/` and are owned by maintainers and the product owner.
- architecture decisions live in `docs/architecture/` and are owned by maintainers.
- durable decisions with real alternatives get an architecture decision record in [`docs/adr/`](docs/adr/); everything else is a line in the relevant topic document. the threshold is in [`GOVERNANCE.md`](GOVERNANCE.md).
- the open standards the project implements are inventoried in [`docs/architecture/standards.md`](docs/architecture/standards.md).
- approved design artifacts live in `docs/design/`.
- implementation work is tracked through individual maintainer-created issues, not a single tracker.

contributors must not invent unresolved product behavior or expand an issue beyond its accepted scope. product-owner review is required only when a pull request changes approved user-visible behavior, copy, or visual output.

## branches and pull requests

- create a focused branch for one acknowledged issue.
- keep the diff limited to the accepted scope.
- link the issue in the pull request.
- describe behavior, schema or api impact, risk, validation, and recovery implications.
- include screenshots or recordings for user-visible changes.
- keep a pull request draft while required review or evidence is pending.

## validation

run the checks relevant to the changed area.

backend:

```sh
cd backend
make fmt
make build
make test
make lint
```

flutter:

```sh
cd app
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

include migration, integration, accessibility, small-screen, privacy, or manual evidence when the issue requires it.

## commit messages

- language: english, always.
- format: `<type>: description`, imperative mood, lowercase after the colon.
- allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `style`, `perf`, `build`, `ci`, `revert`.
- subject line: 50 characters maximum.
- wrap body lines at 72 characters.

## authorship

ai-assisted contributions are allowed, but the human contributor is solely responsible for the result. ai tools must never appear as commit authors, committers, or `Co-Authored-By:` trailers.

enable repository hooks once per clone:

```sh
git config core.hooksPath .githooks
```

## sensitive information

never include secrets, credentials, access tokens, private phone numbers, personal data, production payloads, or precise private locations in issues, discussions, pull requests, commits, logs, screenshots, or fixtures.

security vulnerabilities must not be reported publicly. follow [`SECURITY.md`](SECURITY.md).

## conduct

participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## getting help

[`SUPPORT.md`](SUPPORT.md) routes bug reports, ideas, security reports, and questions to the right place.
