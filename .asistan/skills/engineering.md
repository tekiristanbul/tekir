# engineering

- keep changes small and scoped to the task.
- prefer editing existing files over adding new abstractions.
- write tests for behavior you change.
- leave the codebase in a state you would want to review.
- follow `CONTRIBUTING.md`: commit subject `<type>: description`, lowercase
  after the colon, 50 chars max, english only. never add ai-attribution or
  `Co-Authored-By:`/`Author:` trailers referencing an ai tool.
- backend (`backend/`, go): test with `make test`, lint with `make lint`,
  format with `make fmt` (see `backend/Makefile`).
- app (`app/`, flutter/dart): test with `flutter test` from `app/`.
- repo hooks (`git config core.hooksPath .githooks`) enforce the commit
  message rules above — assume they're active in the agent workspace.
- when the implementation involves a non-trivial tradeoff (a real
  alternative existed and you picked one over it — library choice, schema
  shape, sync vs async, where a boundary sits), write a short decision
  note under `docs/architecture/` using the existing one-file-per-topic
  convention (add to the relevant topic file, or a new one if none fits).
  state what was chosen and why, and what was ruled out. skip this for
  routine changes with no real alternative on the table.
- before finishing, write the commit message for your change to
  `.asistan-commit-message` at the repo root: `<type>: description` per
  `CONTRIBUTING.md` above, describing what you actually changed — not a
  placeholder. This is what gets committed and used as the PR title. It's
  removed before staging, so it never lands in the commit itself.
