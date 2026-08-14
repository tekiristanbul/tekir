package repository

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
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
	AuthorUserID   pgtype.UUID
	Comment        pgtype.Text
	CreatedAt      pgtype.Timestamptz
	Statuses       []string
	// IdempotencyKey (issue #80) is nullable — set only when the caller
	// presented an Idempotency-Key header, mirroring cats/media's own
	// idempotency-key field exactly.
	IdempotencyKey pgtype.Text
	// NeedsHelp/NeedsHelpExpiresAt (issue #101) mark the update as a help
	// call under the combined flag model — expiry must be set exactly when
	// the flag is (updates_needs_help_fields_ck). NeedsHelpCategory is set
	// only by the 0.1 compat needs-help endpoint, recording the category a
	// legacy client sent as legacy metadata; the combined write path never
	// sets it. kind stays 'ordinary' for every row this writes.
	NeedsHelp          bool
	NeedsHelpCategory  pgtype.Text
	NeedsHelpExpiresAt pgtype.Timestamptz
	// MediaID (issue #153) is nullable — set only when the caller attached a
	// photo, already uploaded via POST /v1/media and resolved/owned by
	// CatsService.CreateOrdinaryUpdate before this write runs.
	MediaID pgtype.UUID
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
// CreateCatWithMediaParams groups the atomic write behind POST /v1/cats
// (issue #70): the media row for the uploaded photo and the cats row
// referencing it commit together or not at all — never an orphan cat with
// no photo, or an orphan media row no cat references. Cat.PrimaryPhotoID is
// overwritten with the media row's own id once it's inserted; callers don't
// need to (and shouldn't) set it themselves.
type CreateCatWithMediaParams struct {
	Media CreateMediaParams
	Cat   CreateCatParams
}

// CreateCatWithMediaRow is the pair of rows CreateCatWithMedia commits.
type CreateCatWithMediaRow struct {
	Cat   CreateCatRow
	Media Medium
}

// CreateCatWithMedia inserts the media row for a new cat's required photo,
// then the cats row referencing it via primary_photo_id, then the cat_media
// archive row linking the two (issue #121: the cover photo is the cat's
// first photo-archive entry, backing the design's cover photo-count pill
// and "medya" tab from the moment a cat exists), all in one transaction —
// mirroring CreateOrdinaryUpdate's shape below. If any insert fails
// (including the cats-table idempotency conflict — see CreateCat's comment
// — which surfaces as pgx.ErrNoRows here), the whole transaction rolls
// back: the media row never survives without a cat pointing at it, and the
// cat never survives without its archive entry. CatsService.Create is
// responsible for compensating the object already uploaded to storage on
// any error this returns, and for resolving the idempotency-conflict case
// to the cat an earlier, successful call already created.
func (s *Store) CreateCatWithMedia(ctx context.Context, arg CreateCatWithMediaParams) (CreateCatWithMediaRow, error) {
	var result CreateCatWithMediaRow
	err := s.withTx(ctx, func(q *Queries) error {
		media, err := q.CreateMedia(ctx, arg.Media)
		if err != nil {
			return err
		}
		catParams := arg.Cat
		catParams.PrimaryPhotoID = pgtype.UUID{Bytes: media.ID.Bytes, Valid: true}
		cat, err := q.CreateCat(ctx, catParams)
		if err != nil {
			return err
		}
		if _, err := q.CreateCatMedia(ctx, CreateCatMediaParams{
			CatID:     pgtype.UUID{Bytes: cat.ID.Bytes, Valid: true},
			MediaID:   pgtype.UUID{Bytes: media.ID.Bytes, Valid: true},
			CreatedAt: cat.CreatedAt,
		}); err != nil {
			return err
		}
		result = CreateCatWithMediaRow{Cat: cat, Media: media}
		return nil
	})
	return result, err
}

func (s *Store) CreateOrdinaryUpdate(ctx context.Context, arg CreateOrdinaryUpdateParams) (CreateUpdateRow, error) {
	var row CreateUpdateRow
	err := s.withTx(ctx, func(q *Queries) error {
		var err error
		row, err = q.CreateUpdate(ctx, CreateUpdateParams{
			ID:                 arg.ID,
			CatID:              arg.CatID,
			Kind:               "ordinary",
			Comment:            arg.Comment,
			CreatedAt:          arg.CreatedAt,
			NeedsHelp:          arg.NeedsHelp,
			NeedsHelpCategory:  arg.NeedsHelpCategory,
			NeedsHelpExpiresAt: arg.NeedsHelpExpiresAt,
			AuthorDeviceID:     arg.AuthorDeviceID,
			AuthorUserID:       arg.AuthorUserID,
			IdempotencyKey:     arg.IdempotencyKey,
			MediaID:            arg.MediaID,
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
		if arg.MediaID.Valid {
			// mirrors CreateCatWithMedia's own archive insert: an update's
			// attached photo/video (issue #153/#167) belongs in the cat's
			// gallery too, not just on the timeline entry. On conflict do
			// nothing (same media reused across two updates for this cat)
			// surfaces as pgx.ErrNoRows, which is not an error here — the
			// gallery entry already exists.
			if _, err := q.CreateCatMedia(ctx, CreateCatMediaParams{
				CatID:     arg.CatID,
				MediaID:   arg.MediaID,
				CreatedAt: arg.CreatedAt,
			}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		return q.CreateNotificationOutbox(ctx, row.ID)
	})
	return row, err
}

// CorrectOwnUpdateParams groups the atomic write behind
// PATCH /v1/cats/{cat_id}/updates/{update_id} (issue #80): the update row's
// comment/updated_at and its full update_statuses replacement commit
// together or not at all — a partial write could otherwise leave a
// statuses set inconsistent with what the caller actually submitted.
type CorrectOwnUpdateParams struct {
	ID           pgtype.UUID
	CatID        pgtype.UUID
	AuthorUserID pgtype.UUID
	// SetComment/Comment and ReplaceStatuses/Statuses are presence-aware
	// (issue #105): a PATCH body that omitted the field leaves the row's
	// existing value untouched — SetComment/ReplaceStatuses false means
	// Comment/Statuses carry no meaning and nothing is written.
	SetComment      bool
	Comment         pgtype.Text
	UpdatedAt       pgtype.Timestamptz
	WindowStart     pgtype.Timestamptz
	ReplaceStatuses bool
	Statuses        []string
	// ClearNeedsHelp (issue #101) removes the row's help mark inside the
	// same conditional statement — see CorrectOrdinaryUpdate in
	// db/queries/updates.sql, including its post-state invariant (at least
	// one status, or the flag survives), which is fed from Statuses when
	// ReplaceStatuses is set and from the row's existing update_statuses
	// otherwise.
	ClearNeedsHelp bool
}

// CorrectOwnUpdateRow is CorrectOrdinaryUpdateRow plus the statuses the
// corrected row actually carries after the write — the replacement set
// when one was supplied, the preserved existing set otherwise, read
// inside the same transaction either way.
type CorrectOwnUpdateRow struct {
	CorrectOrdinaryUpdateRow
	Statuses []string
}

// CorrectOwnUpdate applies an in-window correction to the caller's own
// ordinary update. The conditional CorrectOrdinaryUpdate update is the
// entire authorization/concurrency/expiry check (see updates.sql); pgx's
// ErrNoRows from a :one query with no matching row is the signal to the
// caller (service.CatsService.CorrectOwnUpdate) that it affected zero rows
// and must disambiguate why via GetUpdateForCorrectionCheck. Statuses are
// replaced (delete-then-reinsert, mirroring CreateOrdinaryUpdate's own
// insert loop) only when the request carried a replacement set, only once
// the conditional update itself succeeds, inside the same transaction;
// an omitted set is instead read back so the caller can echo what the
// row still carries (issue #105).
func (s *Store) CorrectOwnUpdate(ctx context.Context, arg CorrectOwnUpdateParams) (CorrectOwnUpdateRow, error) {
	var row CorrectOwnUpdateRow
	err := s.withTx(ctx, func(q *Queries) error {
		updated, err := q.CorrectOrdinaryUpdate(ctx, CorrectOrdinaryUpdateParams{
			SetComment:      arg.SetComment,
			Comment:         arg.Comment,
			UpdatedAt:       arg.UpdatedAt,
			ClearNeedsHelp:  arg.ClearNeedsHelp,
			ID:              arg.ID,
			CatID:           arg.CatID,
			AuthorUserID:    arg.AuthorUserID,
			WindowStart:     arg.WindowStart,
			ReplaceStatuses: arg.ReplaceStatuses,
			HasStatuses:     len(arg.Statuses) > 0,
		})
		if err != nil {
			return err
		}
		row.CorrectOrdinaryUpdateRow = updated

		if !arg.ReplaceStatuses {
			statuses, err := q.ListUpdateStatuses(ctx, arg.ID)
			if err != nil {
				return err
			}
			row.Statuses = statuses
			return nil
		}

		if err := q.ReplaceUpdateStatuses(ctx, arg.ID); err != nil {
			return err
		}
		for _, status := range arg.Statuses {
			if err := q.CreateUpdateStatus(ctx, CreateUpdateStatusParams{UpdateID: arg.ID, Status: status}); err != nil {
				return err
			}
		}
		row.Statuses = arg.Statuses
		return nil
	})
	return row, err
}

// DeleteOwnUpdate (soft-deleting the caller's own ordinary update within
// the correction window) needs no Store-level wrapper: it's a single
// statement (see the generated Queries.DeleteOwnUpdate), already promoted
// through Store's embedded *Queries — no statuses replacement is needed
// either, since a deleted update's statuses are simply never read again
// (ListCatUpdates filters on updates.deleted_at, not update_statuses).

// DeleteAccount removes one account and everything the product decision on
// issue #242 defines as its data, in one transaction and in foreign-key-safe
// order (see db/queries/account_deletion.sql for what each step covers and
// why). It returns the object-store keys of the media it deleted, collected
// before the rows went away — the caller removes those objects afterwards,
// best-effort, because object storage cannot participate in this
// transaction.
//
// Retry-safe by construction: every statement is an unconditional delete of
// rows matching this account, so a second call after a partial failure (or
// after a successful one) simply matches nothing. There is no intermediate
// "deleting" state for a retry to get stuck behind.
func (s *Store) DeleteAccount(ctx context.Context, userID pgtype.UUID, phone string) ([]string, error) {
	var objectKeys []string
	err := s.withTx(ctx, func(q *Queries) error {
		keys, err := q.ListAccountObjectKeys(ctx, userID)
		if err != nil {
			return err
		}
		objectKeys = keys

		// Order matters: children before parents, and anything referencing
		// media before the media rows themselves.
		steps := []func(context.Context, pgtype.UUID) error{
			q.DeleteAccountNotifications,
			q.DeleteAccountOutbox,
			q.DeleteAccountUpdateStatuses,
			q.DeleteAccountUpdates,
			q.DeleteAccountFollows,
			q.DeleteAccountReports,
			q.DeleteAccountBlocks,
			q.ClearCoversReferencingAccountMedia,
			q.DeleteAccountCatMedia,
			q.DeleteAccountCats,
			q.DeleteAccountMedia,
			q.DetachAccountDevices,
			q.DeleteAccountRefreshTokens,
		}
		for _, step := range steps {
			if err := step(ctx, userID); err != nil {
				return err
			}
		}

		if err := q.DeleteAccountOtpCodes(ctx, phone); err != nil {
			return err
		}
		return q.DeleteUser(ctx, userID)
	})
	if err != nil {
		return nil, err
	}
	return objectKeys, nil
}
