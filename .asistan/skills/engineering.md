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
