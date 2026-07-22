// Package service holds business logic between handlers and repositories.
package service

import "context"

// Pinger is satisfied by repository.Store; kept as an interface here so
// HealthService stays testable without a real database connection.
type Pinger interface {
	Ping(ctx context.Context) error
}

type HealthService struct {
	db Pinger
}

func NewHealthService(db Pinger) *HealthService {
	return &HealthService{db: db}
}

// Ready reports whether the service's dependencies are reachable.
func (h *HealthService) Ready(ctx context.Context) error {
	return h.db.Ping(ctx)
}
