package service

import (
	"context"
	"errors"
	"log/slog"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// AccountDeletionStore is satisfied by repository.Store; kept as an
// interface so AccountsService stays testable without a real database.
type AccountDeletionStore interface {
	GetUserByID(ctx context.Context, id pgtype.UUID) (repository.User, error)
	DeleteAccount(ctx context.Context, userID pgtype.UUID, phone string) ([]string, error)
}

// AccountsService owns in-app account deletion (issue #242, apple
// guideline 5.1.1(v)). Deletion is terminal — there is no deactivate or
// restore state — and it is the account holder's own action: the caller is
// always the authenticated session, and there is no path for one account to
// delete another.
type AccountsService struct {
	db      AccountDeletionStore
	objects ObjectStore
}

func NewAccountsService(db AccountDeletionStore, objects ObjectStore) *AccountsService {
	return &AccountsService{db: db, objects: objects}
}

// Delete removes the account and the data the product decision on issue
// #242 defines as its own: identity, auth state, follows, authored updates,
// uploaded media (rows and objects), and the cats it created along with
// everything attached to them.
//
// Idempotent by design. An account that is already gone reports success
// rather than 404: the caller asked for it to not exist, and that is the
// state they get. This matters because the client clears its local session
// only after a confirmed success — a retry after a dropped response must
// not strand it holding credentials for an account that no longer exists.
//
// The database work is one transaction (Store.DeleteAccount). Object-store
// cleanup happens after it commits, because object storage cannot join that
// transaction: a failure there leaves an unreferenced object, which is
// logged for operational follow-up but does not fail the deletion — the
// rows naming that object are already gone, so there is nothing left for a
// retry to find, and reporting failure would leave the user believing their
// account survived when it did not.
func (s *AccountsService) Delete(ctx context.Context, userID string) error {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return err
	}
	id := pgtype.UUID{Bytes: parsed, Valid: true}

	user, err := s.db.GetUserByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}

	objectKeys, err := s.db.DeleteAccount(ctx, id, user.Phone)
	if err != nil {
		return err
	}

	for _, key := range objectKeys {
		if err := s.objects.Delete(ctx, key); err != nil {
			slog.Error(
				"failed to delete media object during account deletion",
				"key", key,
				"error", err,
			)
		}
	}
	return nil
}
