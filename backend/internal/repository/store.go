package repository

import (
	"context"

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
