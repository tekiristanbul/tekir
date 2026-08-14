package service

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// ErrInvalidBlockedUserID means blocked_user_id wasn't a well-formed uuid.
var ErrInvalidBlockedUserID = errors.New("invalid blocked user id")

// ErrCannotBlockSelf means the caller asked to block their own account.
// Rejected here rather than left to user_blocks_no_self_block_ck so the
// client gets a 400 it can explain instead of a database error.
var ErrCannotBlockSelf = errors.New("cannot block yourself")

// ErrBlockedUserNotFound means blocked_user_id is well-formed but no such
// account exists.
var ErrBlockedUserNotFound = errors.New("blocked user not found")

// BlockedAccount is one entry of the caller's own block list — the only
// read that ever returns blocks, and always scoped to their own account
// (blocks are private: the blocked party is never told, per issue #234).
type BlockedAccount struct {
	UserID      string
	DisplayName *string
	CreatedAt   time.Time
}

// BlocksStore is satisfied by repository.Store; kept as an interface so
// BlocksService stays testable without a real database connection.
type BlocksStore interface {
	CreateBlock(ctx context.Context, arg repository.CreateBlockParams) error
	DeleteBlock(ctx context.Context, arg repository.DeleteBlockParams) error
	ListBlockedAccounts(ctx context.Context, blockerUserID pgtype.UUID) ([]repository.ListBlockedAccountsRow, error)
	GetUserByID(ctx context.Context, id pgtype.UUID) (repository.User, error)
}

// BlocksService owns account-to-account blocking (issue #234). It only
// writes the relationship; what a block hides is decided at read time by
// every cat-returning query, keyed on the cat's owner — nothing here
// deletes or hides content, and the blocked account is never notified.
type BlocksService struct {
	db BlocksStore
}

func NewBlocksService(db BlocksStore) *BlocksService {
	return &BlocksService{db: db}
}

// Block records that blockerUserID no longer wants to see cats owned by
// blockedUserID. Idempotent: blocking an account that is already blocked
// succeeds and changes nothing.
func (s *BlocksService) Block(ctx context.Context, blockerUserID, blockedUserID string) error {
	blocker, blocked, err := s.parsePair(blockerUserID, blockedUserID)
	if err != nil {
		return err
	}

	// The target must exist: blocking an id that was never an account is a
	// client bug, and answering 404 keeps this endpoint from being usable
	// as an account-existence oracle for arbitrary uuids... which it would
	// be either way, so it costs nothing and reports the real problem.
	if _, err := s.db.GetUserByID(ctx, blocked); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrBlockedUserNotFound
		}
		return err
	}

	return s.db.CreateBlock(ctx, repository.CreateBlockParams{
		BlockerUserID: blocker,
		BlockedUserID: blocked,
	})
}

// Unblock removes the relationship, restoring visibility. Idempotent:
// unblocking an account that isn't blocked succeeds and changes nothing —
// the follow rows and everything else survived the block untouched, so
// nothing has to be rebuilt here.
func (s *BlocksService) Unblock(ctx context.Context, blockerUserID, blockedUserID string) error {
	blocker, blocked, err := s.parsePair(blockerUserID, blockedUserID)
	if err != nil {
		return err
	}
	return s.db.DeleteBlock(ctx, repository.DeleteBlockParams{
		BlockerUserID: blocker,
		BlockedUserID: blocked,
	})
}

// ListBlocked returns the caller's own blocks, newest first.
func (s *BlocksService) ListBlocked(ctx context.Context, blockerUserID string) ([]BlockedAccount, error) {
	blocker, err := uuid.Parse(blockerUserID)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.ListBlockedAccounts(ctx, pgtype.UUID{Bytes: blocker, Valid: true})
	if err != nil {
		return nil, err
	}
	out := make([]BlockedAccount, 0, len(rows))
	for _, r := range rows {
		out = append(out, BlockedAccount{
			UserID:      uuid.UUID(r.BlockedUserID.Bytes).String(),
			DisplayName: textPtr(r.DisplayName),
			CreatedAt:   r.CreatedAt.Time,
		})
	}
	return out, nil
}

// parsePair validates both sides. blockerUserID always comes from the
// authenticated session (never the request body), so a malformed one is a
// server-side bug, not client input; blockedUserID is client input and
// gets the typed error the handler maps to 400.
func (s *BlocksService) parsePair(blockerUserID, blockedUserID string) (pgtype.UUID, pgtype.UUID, error) {
	blocker, err := uuid.Parse(blockerUserID)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, err
	}
	blocked, err := uuid.Parse(blockedUserID)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, ErrInvalidBlockedUserID
	}
	if blocker == blocked {
		return pgtype.UUID{}, pgtype.UUID{}, ErrCannotBlockSelf
	}
	return pgtype.UUID{Bytes: blocker, Valid: true}, pgtype.UUID{Bytes: blocked, Valid: true}, nil
}
