package service

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// FollowsStore is satisfied by repository.Store; kept as an interface here
// so FollowsService stays testable without a real database connection.
type FollowsStore interface {
	CatExists(ctx context.Context, id pgtype.UUID) (bool, error)
	CreateFollow(ctx context.Context, arg repository.CreateFollowParams) error
	DeleteFollow(ctx context.Context, arg repository.DeleteFollowParams) error
	ListFollowedCats(ctx context.Context, deviceID pgtype.UUID) ([]repository.ListFollowedCatsRow, error)
}

// FollowsService handles device-owned cat follows (issue #44): a valid
// device credential is enough to follow/unfollow a cat and list its own
// followed cats — no account/login required, matching docs/product/
// trust.md's "guests can follow/favorite a cat" decision.
type FollowsService struct {
	db    FollowsStore
	clock func() time.Time
}

// FollowsServiceOption configures optional FollowsService behavior.
type FollowsServiceOption func(*FollowsService)

// WithFollowsClock overrides the clock used to decide whether a followed
// cat's needs-help alert is still active (mirrors CatsService's WithClock,
// see issue #23) — production wiring doesn't need this, but it lets tests
// construct exact expiry-boundary scenarios deterministically.
func WithFollowsClock(clock func() time.Time) FollowsServiceOption {
	return func(s *FollowsService) { s.clock = clock }
}

func NewFollowsService(db FollowsStore, opts ...FollowsServiceOption) *FollowsService {
	s := &FollowsService{db: db, clock: time.Now}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// Follow records that deviceID follows the cat identified by catID
// (issue #44). Idempotent: following an already-followed cat succeeds
// without creating a duplicate row — Store.CreateFollow's on-conflict
// clause makes this safe even under concurrent duplicate requests.
// deviceID is never client-supplied: it comes from the authenticated
// device context the device-token middleware places on the request (see
// CreateOrdinaryUpdate for the same convention), so it is always a
// well-formed uuid the middleware itself generated.
func (s *FollowsService) Follow(ctx context.Context, catID, deviceID string) error {
	cid, err := parseCatID(catID)
	if err != nil {
		return err
	}
	did, err := uuid.Parse(deviceID)
	if err != nil {
		return err
	}

	exists, err := s.db.CatExists(ctx, cid)
	if err != nil {
		return err
	}
	if !exists {
		return ErrCatNotFound
	}

	return s.db.CreateFollow(ctx, repository.CreateFollowParams{
		DeviceID: pgtype.UUID{Bytes: did, Valid: true},
		CatID:    cid,
	})
}

// Unfollow removes deviceID's follow of the cat identified by catID (issue
// #44). Idempotent: unfollowing a cat this device doesn't currently follow
// deletes zero rows and still succeeds. Mirrors Follow's 404-on-unknown-cat
// behavior rather than silently no-op-ing on a cat id that never existed.
func (s *FollowsService) Unfollow(ctx context.Context, catID, deviceID string) error {
	cid, err := parseCatID(catID)
	if err != nil {
		return err
	}
	did, err := uuid.Parse(deviceID)
	if err != nil {
		return err
	}

	exists, err := s.db.CatExists(ctx, cid)
	if err != nil {
		return err
	}
	if !exists {
		return ErrCatNotFound
	}

	return s.db.DeleteFollow(ctx, repository.DeleteFollowParams{
		DeviceID: pgtype.UUID{Bytes: did, Valid: true},
		CatID:    cid,
	})
}

// ListFollows returns deviceID's followed cats, ordered by most recent cat
// activity (issue #44) — never another device's follows, since the
// underlying query is scoped to deviceID throughout. The returned CatMarker
// shape is exactly the map/detail summary a client already knows how to
// render, including active needs-help state, rather than a bespoke
// follows-only representation.
func (s *FollowsService) ListFollows(ctx context.Context, deviceID string) ([]CatMarker, error) {
	did, err := uuid.Parse(deviceID)
	if err != nil {
		return nil, err
	}

	rows, err := s.db.ListFollowedCats(ctx, pgtype.UUID{Bytes: did, Valid: true})
	if err != nil {
		return nil, err
	}

	markers := make([]CatMarker, 0, len(rows))
	for _, r := range rows {
		markers = append(markers, CatMarker{
			ID:           uuid.UUID(r.ID.Bytes).String(),
			Name:         r.Name.String,
			PrimaryPhoto: r.PhotoUrl.String,
			Lat:          r.Lat,
			Lng:          r.Lng,
			AreaLabel:    textPtr(r.AreaLabel),
			ActiveAlert:  deriveActiveAlert(s.clock, r.NeedsHelpCategory, r.NeedsHelpCreatedAt, r.NeedsHelpExpiresAt),
			LastUpdateAt: timestamptzPtr(r.LastUpdateAt),
		})
	}
	return markers, nil
}
