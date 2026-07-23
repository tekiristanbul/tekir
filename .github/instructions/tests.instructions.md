---
applyTo: "backend/**/*_test.go,app/test/**/*.dart,app/integration_test/**/*.dart"
---

# tests

- add unit, integration, or widget tests appropriate to the changed behavior and preserve existing regression coverage.
- tests must not use real network calls, a real maps api key, or wall-clock time.
- prefer injected clocks, deterministic fixtures, local test databases, and fakes at existing boundaries.
- cover user-visible state transitions and malformed, missing, empty, and boundary inputs where applicable.
- do not weaken assertions or delete coverage merely to make a change pass.
