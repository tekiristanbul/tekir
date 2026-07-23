---
applyTo: "backend/**/*.go,backend/**/*.sql,backend/go.mod,backend/go.sum,backend/Makefile"
---

# backend

- run `gofmt`, `go vet ./...`, `go test ./...`, and the repository lint target when available.
- keep business logic out of handlers; preserve testable service and repository boundaries.
- propagate `context.Context`, handle errors explicitly, and use parameterized sql.
- make ordering and pagination deterministic.
- inject clocks for time-dependent behavior; tests must not depend on wall-clock time.
- avoid unnecessary abstractions and new dependencies.
- update sqlc-generated code through the existing generation command when queries change.
