package service

import (
	"context"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// TxRunner runs fn against a single database transaction, committing only
// if fn returns nil. Satisfied by *repository.Store (see Store.WithinTx).
// AuthService and SessionService use it to keep a multi-step write —
// otp consumption plus account resolution, device linking, and session
// issuance; or refresh-token rotation plus its replacement — atomic, so a
// later failure rolls back the earlier steps too instead of permanently
// burning an otp code or refresh token.
//
// Optional: when nil, both services fall back to calling their narrow
// store interfaces directly, one statement at a time. Every individual
// statement used this way is still independently atomic (a single sql
// UPDATE is never itself racy), so the fallback path is exactly what unit
// tests exercise with hand-rolled fakes — real cross-statement
// all-or-nothing behavior is a repository/database concern verified by
// postgres integration tests instead (see auth_integration_test.go),
// since in-memory fakes can't meaningfully stand in for real transaction
// rollback.
type TxRunner interface {
	WithinTx(ctx context.Context, fn func(*repository.Queries) error) error
}
