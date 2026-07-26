package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"log/slog"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// ErrMediaTooLarge means the uploaded file exceeds MediaService's configured
// byte-size limit, checked before any decoding is attempted (issue #70: a
// request can't force the server to decompress an arbitrarily large image).
var ErrMediaTooLarge = errors.New("media too large")

// ErrUnsupportedMediaType means the file decoded to an image format outside
// this slice's supported set (jpeg, png) — image_picker's common capture/
// selection outputs. Anything else is a clean rejection, not a crash.
var ErrUnsupportedMediaType = errors.New("unsupported media type")

// ErrMalformedMedia means the uploaded bytes are empty or don't decode as a
// genuine image at all, regardless of the claimed content-type or filename
// extension — client-supplied metadata is never trusted on its own.
var ErrMalformedMedia = errors.New("malformed media")

// ErrMediaDimensionsTooLarge means the image's own declared width*height
// exceeds maxImagePixels. A small, well-compressed file can still decode to
// an enormous pixel buffer (a decompression bomb) — checked via
// image.DecodeConfig, which reads only the header, before ever decoding the
// full image, so this never depends on the compressed byte size alone.
var ErrMediaDimensionsTooLarge = errors.New("media dimensions too large")

// maxImagePixels caps width*height before a full decode is attempted.
// Generous enough for any real phone camera photo (40 megapixels is well
// above typical 12-48MP sensors' output once jpeg-compressed) while
// rejecting a maliciously-crafted image whose declared dimensions imply a
// pixel buffer far larger than its compressed size suggests.
const maxImagePixels = 40_000_000

// processedMedia is a validated, re-encoded upload ready for an ObjectStore.
// Re-encoding from decoded pixel data (rather than storing the original
// bytes) is what strips any exif/metadata the original file carried —
// docs/product/privacy.md requires the upload flow account for media
// possibly carrying location/contextual metadata; discarding it here means
// nothing downstream ever has to.
type processedMedia struct {
	data        []byte
	contentType string
	extension   string
}

// mediaPipeline is the validation+storage logic shared by MediaService
// (standalone POST /v1/media) and CatsService.Create (a photo embedded in
// POST /v1/cats) — both need identical validation before either writes to
// the database, but each controls its own transaction boundary, so this
// type never touches a database itself.
type mediaPipeline struct {
	store    ObjectStore
	maxBytes int
}

func newMediaPipeline(store ObjectStore, maxBytes int) *mediaPipeline {
	return &mediaPipeline{store: store, maxBytes: maxBytes}
}

// process rejects anything empty, oversized, or not a genuinely decodable
// jpeg/png (regardless of claimed content-type), then re-encodes the
// decoded pixels. It performs no i/o — see upload for the storage step.
func (p *mediaPipeline) process(raw []byte) (processedMedia, error) {
	if len(raw) == 0 {
		return processedMedia{}, ErrMalformedMedia
	}
	if len(raw) > p.maxBytes {
		return processedMedia{}, ErrMediaTooLarge
	}

	// image.DecodeConfig reads only the header (width/height/color model),
	// never the pixel data — cheap enough to reject an oversized image
	// before image.Decode below would allocate its full pixel buffer.
	cfg, _, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		return processedMedia{}, ErrMalformedMedia
	}
	// cfg.Width/cfg.Height come straight from the file's own header — a
	// crafted file can declare values whose product overflows int before
	// this check ever runs. Dividing instead of multiplying avoids that;
	// non-positive dimensions are rejected as malformed outright, not
	// "too large" (they're not a valid image regardless of size).
	if cfg.Width <= 0 || cfg.Height <= 0 {
		return processedMedia{}, ErrMalformedMedia
	}
	if cfg.Width > maxImagePixels/cfg.Height {
		return processedMedia{}, ErrMediaDimensionsTooLarge
	}

	img, format, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return processedMedia{}, ErrMalformedMedia
	}

	var buf bytes.Buffer
	switch format {
	case "jpeg":
		if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
			return processedMedia{}, fmt.Errorf("re-encode jpeg: %w", err)
		}
		return processedMedia{data: buf.Bytes(), contentType: "image/jpeg", extension: "jpg"}, nil
	case "png":
		if err := png.Encode(&buf, img); err != nil {
			return processedMedia{}, fmt.Errorf("re-encode png: %w", err)
		}
		return processedMedia{data: buf.Bytes(), contentType: "image/png", extension: "png"}, nil
	default:
		return processedMedia{}, ErrUnsupportedMediaType
	}
}

// upload stores processed under a fresh, random key and returns the
// resulting object key and url. Callers are responsible for compensating
// (deleting the object) if a subsequent database write fails.
func (p *mediaPipeline) upload(ctx context.Context, processed processedMedia) (key, url string, err error) {
	key = uuid.NewString() + "." + processed.extension
	url, err = p.store.Put(ctx, key, processed.contentType, processed.data)
	return key, url, err
}

// Media is the minimal shape a client needs back from an upload.
type Media struct {
	ID  string
	URL string
}

// MediaStore is satisfied by repository.Store; kept as an interface so
// MediaService stays testable without a real database connection.
type MediaStore interface {
	CreateMedia(ctx context.Context, arg repository.CreateMediaParams) (repository.Medium, error)
	GetMediaByIdempotencyKey(ctx context.Context, arg repository.GetMediaByIdempotencyKeyParams) (repository.Medium, error)
}

// MediaService handles standalone media uploads (POST /v1/media). Cat
// creation's own embedded photo (POST /v1/cats) shares this package's
// mediaPipeline but writes its media+cats rows together in one transaction
// via CatsService.Create/repository.Store.CreateCatWithMedia instead of
// going through MediaService.
type MediaService struct {
	db       MediaStore
	pipeline *mediaPipeline
}

func NewMediaService(db MediaStore, store ObjectStore, maxBytes int) *MediaService {
	return &MediaService{db: db, pipeline: newMediaPipeline(store, maxBytes)}
}

// Upload validates and stores raw, attributing it to the authenticated
// account identified by userID (never client-supplied) with deviceID
// (optional, installation/abuse-control association only) recorded
// alongside it. idempotencyKey, when non-nil, makes a retried upload with
// the same key return the original result instead of creating a second
// media row or a second stored object.
func (s *MediaService) Upload(ctx context.Context, userID, deviceID string, idempotencyKey *string, raw []byte) (Media, error) {
	uid, err := uuid.Parse(userID)
	if err != nil {
		return Media{}, err
	}
	authorDeviceID, err := optionalUUID(deviceID)
	if err != nil {
		return Media{}, err
	}
	ownerUUID := pgtype.UUID{Bytes: uid, Valid: true}
	idemKey := nullableText(idempotencyKey)

	if idemKey.Valid {
		existing, err := s.db.GetMediaByIdempotencyKey(ctx, repository.GetMediaByIdempotencyKeyParams{
			UploadedByUserID: ownerUUID,
			IdempotencyKey:   idemKey,
		})
		if err == nil {
			return toMedia(existing), nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return Media{}, err
		}
	}

	processed, err := s.pipeline.process(raw)
	if err != nil {
		return Media{}, err
	}

	key, url, err := s.pipeline.upload(ctx, processed)
	if err != nil {
		return Media{}, err
	}

	row, err := s.db.CreateMedia(ctx, repository.CreateMediaParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		ObjectKey:          key,
		Url:                url,
		ContentType:        processed.contentType,
		ByteSize:           int32(len(processed.data)),
		UploadedByUserID:   ownerUUID,
		UploadedByDeviceID: authorDeviceID,
		IdempotencyKey:     idemKey,
	})
	if err != nil {
		return s.recoverFromCreateFailure(ctx, err, key, ownerUUID, idemKey)
	}
	return toMedia(row), nil
}

// recoverFromCreateFailure runs after CreateMedia fails to insert: if the
// failure was the idempotency conflict (no row returned, not a real error —
// see db/queries/media.sql's CreateMedia comment) it fetches and returns
// the row a concurrent request already created; otherwise it's a genuine
// error. Either way, the object just uploaded to key is no longer needed
// under this attempt (it's a duplicate of an existing row, or belongs to a
// media row that will never exist) — deleted best-effort so a failed or
// superseded attempt doesn't leak storage. A failed cleanup is logged, not
// escalated: a rare leaked object is an acceptable residual, never an
// orphan database row.
func (s *MediaService) recoverFromCreateFailure(ctx context.Context, createErr error, key string, ownerUUID pgtype.UUID, idemKey pgtype.Text) (Media, error) {
	var result Media
	var err error
	if errors.Is(createErr, pgx.ErrNoRows) && idemKey.Valid {
		existing, getErr := s.db.GetMediaByIdempotencyKey(ctx, repository.GetMediaByIdempotencyKeyParams{
			UploadedByUserID: ownerUUID,
			IdempotencyKey:   idemKey,
		})
		if getErr != nil {
			err = getErr
		} else {
			result = toMedia(existing)
		}
	} else {
		err = createErr
	}

	if delErr := s.pipeline.store.Delete(ctx, key); delErr != nil {
		slog.Error("failed to clean up media object after create failure", "key", key, "error", delErr)
	}
	return result, err
}

func toMedia(row repository.Medium) Media {
	return Media{ID: uuid.UUID(row.ID.Bytes).String(), URL: row.Url}
}
