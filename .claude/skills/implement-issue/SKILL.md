---
name: implement-issue
description: Implement one ready tekir issue with strict scope, updated tests and docs, real validation evidence, and a draft pull request. Use when asked to implement, fix, or build an accepted issue in this repository.
---

# implement-issue

Implement one ready issue and deliver it as a draft pull request.

`AGENTS.md` is the delivery contract: scope rules, source-of-truth order, risk
and evidence requirements, definition of done, and pull request contents all
live there. `CONTRIBUTING.md` carries branch, commit, and validation
conventions, and `GOVERNANCE.md` carries the adr threshold and who approves
what. Follow them; this skill only sequences the work.

## before editing

1. Read the issue and every existing comment, plus the linked issues, pull
   requests, and documents needed to understand the accepted scope.
2. Verify the issue meets the definition of ready in `AGENTS.md`. When a
   product or architecture decision it depends on is missing or contradictory,
   stop and ask one precise question on the issue. Do not invent the decision.
3. Branch from current `main`, one branch for the issue. Preserve unrelated
   local work.
4. Publish a short implementation plan before changing files.

## implementing

- Implement only the accepted scope of this issue and its accepted comments.
  Record anything else discovered as a follow-up.
- Prefer editing existing files over adding abstractions. No speculative
  frameworks, services, runtime dependencies, fake data, or disabled controls.
- Write or update tests for changed behavior: write the test, watch it fail
  for the right reason, then make it pass. Keep regression coverage intact.
- Update the product, architecture, api, database, or design documentation the
  change makes stale. Write an adr only when `GOVERNANCE.md`'s threshold is
  met — a durable decision with real alternatives — as a numbered file in
  `docs/adr/` from `docs/adr/0000-template.md`, added to that directory's
  index, in this same pull request, with the topic document linking to it.
  Everything below that bar is a line in the topic document's `## decisions`
  section.
- User-facing copy is turkish. Commits, pull request text, and github comments
  are english.

## validating

Run the real commands for every area touched, fresh, and read the full output
before reporting anything.

Backend, from `backend/`:

```sh
make fmt
make build
make test
make lint
```

Flutter, from `app/`:

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

Run the whole test file or suite the change touches, not only the test added —
a change can pass its own new test while breaking siblings through shared
setup or state. Never report an unrun or failed check as successful. If a
command cannot be run in this environment, say which one and why instead of
implying it passed.

## delivering

- Commit as `<type>: description`, imperative, lowercase after the colon, 50
  characters maximum, body wrapped at 72. Never add `co-authored-by` or any
  ai-attribution trailer. Never commit secrets, tokens, credentials, or real
  user data. The repository hooks in `.githooks/` enforce the message rules.
- Open one draft pull request containing everything `AGENTS.md` requires:
  closing keyword, implementation summary, schema and api decisions, risk
  level, validations run with their results, intentional exclusions, product
  owner review status, and screenshots or a short demo for user-visible
  changes covering the main state plus applicable loading, empty, error, and
  not-found states.
- Leave the pull request draft. Never mark it ready, approve, merge, or state
  product owner approval on anyone's behalf. Let the closing keyword close the
  issue on merge.
- When the environment cannot open a pull request, prepare the branch and the
  full description and hand it to the maintainer instead.
- Address review feedback only when it is explicit, actionable, and in scope.
  Feedback that needs a new product decision goes back to the issue as a
  question.
