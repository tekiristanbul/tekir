package repository

import (
	"context"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Store wraps generated queries with the pool they run against, so it can
// also answer connectivity checks (see Ping) that aren't a query on their own.
type Store struct {
	*Queries
	pool *pgxpool.Pool
}

func NewStore(pool *pgxpool.Pool) *Store {
	return &Store{Queries: New(pool), pool: pool}
}

func (s *Store) Ping(ctx context.Context) error {
	return s.pool.Ping(ctx)
}

// withTx runs fn against a *Queries bound to a fresh transaction, committing
// only if fn returns nil. Any error from fn (including a check-constraint
// violation raised by the database itself) rolls the transaction back, so
// callers never observe a partial write.
func (s *Store) withTx(ctx context.Context, fn func(*Queries) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if err := fn(s.Queries.WithTx(tx)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// WithinTx is withTx, exported so callers outside this package (currently
// service.AuthService and service.SessionService — see service.TxRunner)
// can keep a multi-step write atomic without repository needing to know
// their business logic. *Queries structurally satisfies every narrow
// store interface a service defines (AuthStore, SessionStore, ...), since
// sqlc generates one method per query on that single type, so the same fn
// can freely call methods from more than one such interface inside one
// transaction.
func (s *Store) WithinTx(ctx context.Context, fn func(*Queries) error) error {
	return s.withTx(ctx, fn)
}

// CreateOrdinaryUpdateParams groups the atomic write behind
// POST /v1/cats/{cat_id}/updates (issue #36): the update row, its
// statuses, and the cat's last_update_at all commit together or not at all.
type CreateOrdinaryUpdateParams struct {
	ID             pgtype.UUID
	CatID          pgtype.UUID
	AuthorDeviceID pgtype.UUID
	Comment        pgtype.Text
	CreatedAt      pgtype.Timestamptz
	Statuses       []string
}

// CreateOrdinaryUpdate inserts an ordinary (kind = 'ordinary') update, its
// update_statuses rows, moves the cat's last_update_at forward, and enqueues
// its notification_outbox row, all in one transaction — this is the only
// call path that ever produces outbox work (issue #38: the update-table-wide
// insert trigger that used to do this was removed in migration 00009, since
// it fired for seed/fixture/direct-repository inserts too, not just a real
// authenticated write). notification_outbox.update_id is unique, so a retry
// of the same update id fails the enqueue and rolls the whole write back
// rather than duplicating notification work.
func (s *Store) CreateOrdinaryUpdate(ctx context.Context, arg CreateOrdinaryUpdateParams) (CreateUpdateRow, error) {
	var row CreateUpdateRow
	err := s.withTx(ctx, func(q *Queries) error {
		var err error
		row, err = q.CreateUpdate(ctx, CreateUpdateParams{
			ID:             arg.ID,
			CatID:          arg.CatID,
			Kind:           "ordinary",
			Comment:        arg.Comment,
			CreatedAt:      arg.CreatedAt,
			AuthorDeviceID: arg.AuthorDeviceID,
		})
		if err != nil {
			return err
		}
		for _, status := range arg.Statuses {
			if err := q.CreateUpdateStatus(ctx, CreateUpdateStatusParams{
				UpdateID: row.ID,
				Status:   status,
			}); err != nil {
				return err
			}
		}
		if err := q.UpdateCatLastUpdateAt(ctx, UpdateCatLastUpdateAtParams{
			ID:           arg.CatID,
			LastUpdateAt: arg.CreatedAt,
		}); err != nil {
			return err
		}
		return q.CreateNotificationOutbox(ctx, CreateNotificationOutboxParams{
			UpdateID: row.ID,
			CatID:    arg.CatID,
		})
	})
	return row, err
}
