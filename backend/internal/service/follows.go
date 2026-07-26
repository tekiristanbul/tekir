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
	ListFollowedCats(ctx context.Context, userID pgtype.UUID) ([]repository.ListFollowedCatsRow, error)
}

// FollowsService handles account-owned cat follows (issue #65: following is
// private per-account state, matching docs/product/trust.md and
// community.md). A valid bearer session is required to follow, unfollow, or
// list followed cats; an optional device token is recorded alongside a new
// follow purely for installation/abuse-control association, never as
// authorization. Pre-existing device-owned follows (issue #44) remain
// readable once the owning device is linked to an account — see
// AuthService.linkDevice's backfill.
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

// Follow records that userID follows the cat identified by catID (issue
// #65). Idempotent: following an already-followed cat succeeds without
// creating a duplicate row — Store.CreateFollow's on-conflict clause makes
// this safe even under concurrent duplicate requests. userID is never
// client-supplied: it comes from the authenticated bearer context the
// RequireBearer middleware places on the request. deviceID is likewise
// never client-supplied (it comes from the optional device-token context,
// if present) and may be "" — a follow written without a device token is
// perfectly valid, it just carries no installation association.
func (s *FollowsService) Follow(ctx context.Context, catID, userID, deviceID string) error {
	cid, err := parseCatID(catID)
	if err != nil {
		return err
	}
	uid, err := uuid.Parse(userID)
	if err != nil {
		return err
	}
	did, err := optionalUUID(deviceID)
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
		UserID:   pgtype.UUID{Bytes: uid, Valid: true},
		DeviceID: did,
		CatID:    cid,
	})
}

// Unfollow removes userID's follow of the cat identified by catID (issue
// #65). Idempotent: unfollowing a cat this account doesn't currently follow
// deletes zero rows and still succeeds. Mirrors Follow's 404-on-unknown-cat
// behavior rather than silently no-op-ing on a cat id that never existed.
func (s *FollowsService) Unfollow(ctx context.Context, catID, userID string) error {
	cid, err := parseCatID(catID)
	if err != nil {
		return err
	}
	uid, err := uuid.Parse(userID)
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
		UserID: pgtype.UUID{Bytes: uid, Valid: true},
		CatID:  cid,
	})
}

// ListFollows returns userID's followed cats, ordered by most recent cat
// activity (issue #65) — never another account's follows, since the
// underlying query is scoped to userID throughout. The returned CatMarker
// shape is exactly the map/detail summary a client already knows how to
// render, including active needs-help state, rather than a bespoke
// follows-only representation.
func (s *FollowsService) ListFollows(ctx context.Context, userID string) ([]CatMarker, error) {
	uid, err := uuid.Parse(userID)
	if err != nil {
		return nil, err
	}

	rows, err := s.db.ListFollowedCats(ctx, pgtype.UUID{Bytes: uid, Valid: true})
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
