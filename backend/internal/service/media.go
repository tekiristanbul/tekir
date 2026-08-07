package service

import (
	"bytes"
	"context"
	"encoding/binary"
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

// ErrMediaDurationTooLong means a video's own moov/mvhd duration exceeds
// maxVideoDurationSeconds — the product's short-form/gif-like cap (issue
// #153 product approval), enforced server-side regardless of what the
// client's own picker allowed.
var ErrMediaDurationTooLong = errors.New("media duration too long")

// maxVideoDurationSeconds is the fixed product cap on an update's attached
// video (issue #153 approval comment: "maximum duration: 30 seconds",
// "short-form / gif-like playback only; long-form video is out of scope").
const maxVideoDurationSeconds = 30

// videoContainer is a narrowly recognized ISO-base-media-file-format
// container brand (issue #153 approval: "constrain supported video formats
// to a narrow set for the first version"). Both mp4 and mov share the same
// box structure this package parses (moov/mvhd) closely enough that no
// separate parser is needed per format.
type videoContainer struct {
	contentType string
	extension   string
}

// videoMajorBrands maps an ftyp box's major_brand to the narrow set of
// containers this pipeline accepts pass-through, unvalidated beyond
// structure/duration: "isom"/"mp42"/"mp41"/"M4V " cover the mp4 files
// Android's camera/gallery and image_picker commonly produce; "qt  " is
// QuickTime's own brand, what iOS's camera records by default.
var videoMajorBrands = map[string]videoContainer{
	"isom": {contentType: "video/mp4", extension: "mp4"},
	"mp42": {contentType: "video/mp4", extension: "mp4"},
	"mp41": {contentType: "video/mp4", extension: "mp4"},
	"M4V ": {contentType: "video/mp4", extension: "mp4"},
	"qt  ": {contentType: "video/quicktime", extension: "mov"},
}

// sniffVideoContainer reads raw's leading ftyp box (mandatory as the first
// box in a conformant mp4/mov file) and reports whether its major_brand is
// one of videoMajorBrands. It never reads past the box header itself, so it
// stays cheap regardless of the file's actual size.
func sniffVideoContainer(raw []byte) (videoContainer, bool) {
	if len(raw) < 12 {
		return videoContainer{}, false
	}
	if string(raw[4:8]) != "ftyp" {
		return videoContainer{}, false
	}
	vc, ok := videoMajorBrands[string(raw[8:12])]
	return vc, ok
}

// isobmffBox is one parsed box header: type plus the offset range of its
// full contents (header included) within the buffer it was read from.
type isobmffBox struct {
	boxType string
	start   int
	end     int
}

// walkBoxes reads a flat sequence of ISO-base-media-file-format boxes
// starting at offset 0 of buf, calling yield for each. It stops at the
// first malformed header (a truncated 8-byte header, a size claiming more
// bytes than buf actually has, or a size too small to contain its own
// header) rather than erroring — callers treat "the box they wanted was
// never found" as malformed, same as a structurally broken file.
func walkBoxes(buf []byte, yield func(isobmffBox) bool) {
	offset := 0
	for offset+8 <= len(buf) {
		size := uint64(binary.BigEndian.Uint32(buf[offset : offset+4]))
		boxType := string(buf[offset+4 : offset+8])
		headerSize := 8
		switch size {
		case 0:
			// A box with size 0 extends to the end of the enclosing buffer
			// (only valid for the last box in a file) — never valid inside
			// a nested box walk, but harmless to resolve the same way.
			size = uint64(len(buf) - offset)
		case 1:
			if offset+16 > len(buf) {
				return
			}
			size = binary.BigEndian.Uint64(buf[offset+8 : offset+16])
			headerSize = 16
		}
		if size < uint64(headerSize) || offset+int(size) > len(buf) || offset+int(size) <= offset {
			return
		}
		if !yield(isobmffBox{boxType: boxType, start: offset, end: offset + int(size)}) {
			return
		}
		offset += int(size)
	}
}

// videoDurationSeconds locates moov > mvhd within raw and returns the
// duration mvhd itself declares (timescale/duration, per ISO/IEC
// 14496-12) — the authoritative source, never trusting a client-supplied
// duration. Returns ErrMalformedMedia when no moov/mvhd box is found, mvhd
// is truncated, or timescale is 0.
func videoDurationSeconds(raw []byte) (float64, error) {
	var moov *isobmffBox
	walkBoxes(raw, func(b isobmffBox) bool {
		if b.boxType == "moov" {
			box := b
			moov = &box
			return false
		}
		return true
	})
	if moov == nil {
		return 0, ErrMalformedMedia
	}

	var mvhd *isobmffBox
	walkBoxes(raw[moov.start+8:moov.end], func(b isobmffBox) bool {
		if b.boxType == "mvhd" {
			box := b
			mvhd = &box
			return false
		}
		return true
	})
	if mvhd == nil {
		return 0, ErrMalformedMedia
	}
	content := raw[moov.start+8+mvhd.start+8 : moov.start+8+mvhd.end]
	if len(content) < 1 {
		return 0, ErrMalformedMedia
	}

	version := content[0]
	var timescale, duration uint64
	switch version {
	case 0:
		if len(content) < 20 {
			return 0, ErrMalformedMedia
		}
		timescale = uint64(binary.BigEndian.Uint32(content[12:16]))
		duration = uint64(binary.BigEndian.Uint32(content[16:20]))
	case 1:
		if len(content) < 32 {
			return 0, ErrMalformedMedia
		}
		timescale = uint64(binary.BigEndian.Uint32(content[20:24]))
		duration = binary.BigEndian.Uint64(content[24:32])
	default:
		return 0, ErrMalformedMedia
	}
	if timescale == 0 {
		return 0, ErrMalformedMedia
	}
	return float64(duration) / float64(timescale), nil
}

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
	// maxVideoBytes gates whether this pipeline accepts video at all: 0
	// (CatsService.Create's pipeline — a cat's own initial photo, issue
	// #70, never a video) means process rejects video bytes exactly like
	// any other unsupported type; MediaService's pipeline (issue #153) sets
	// it so POST /v1/media can accept an update's optional video too.
	maxVideoBytes int
}

func newMediaPipeline(store ObjectStore, maxBytes, maxVideoBytes int) *mediaPipeline {
	return &mediaPipeline{store: store, maxBytes: maxBytes, maxVideoBytes: maxVideoBytes}
}

// process rejects anything empty or oversized, then either passes a
// recognized video through a bounded validation path (issue #153: no
// transcoding for the first version) or re-encodes a genuinely decodable
// jpeg/png (regardless of claimed content-type). It performs no i/o — see
// upload for the storage step.
func (p *mediaPipeline) process(raw []byte) (processedMedia, error) {
	if len(raw) == 0 {
		return processedMedia{}, ErrMalformedMedia
	}
	if p.maxVideoBytes > 0 {
		if vc, ok := sniffVideoContainer(raw); ok {
			return p.processVideo(raw, vc)
		}
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
	var result processedMedia
	switch format {
	case "jpeg":
		if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
			return processedMedia{}, fmt.Errorf("re-encode jpeg: %w", err)
		}
		result = processedMedia{data: buf.Bytes(), contentType: "image/jpeg", extension: "jpg"}
	case "png":
		if err := png.Encode(&buf, img); err != nil {
			return processedMedia{}, fmt.Errorf("re-encode png: %w", err)
		}
		result = processedMedia{data: buf.Bytes(), contentType: "image/png", extension: "png"}
	default:
		return processedMedia{}, ErrUnsupportedMediaType
	}

	// MEDIA_MAX_BYTES bounds what's actually stored, not just what was
	// uploaded — a highly-compressed input (e.g. an indexed-palette PNG)
	// can re-encode to something noticeably larger than raw's own length,
	// so the check above on len(raw) alone isn't sufficient on its own.
	if len(result.data) > p.maxBytes {
		return processedMedia{}, ErrMediaTooLarge
	}
	return result, nil
}

// processVideo validates a video recognized by sniffVideoContainer and
// passes it through unmodified (issue #153 architecture decision: "no
// transcoding required for the first implementation") — raw is stored
// as-is rather than re-encoded, since there's no decoded-pixel
// intermediate for a video the way there is for an image. Duration comes
// from the file's own moov/mvhd box, never a client-supplied value.
func (p *mediaPipeline) processVideo(raw []byte, vc videoContainer) (processedMedia, error) {
	if len(raw) > p.maxVideoBytes {
		return processedMedia{}, ErrMediaTooLarge
	}
	duration, err := videoDurationSeconds(raw)
	if err != nil {
		return processedMedia{}, err
	}
	if duration <= 0 {
		return processedMedia{}, ErrMalformedMedia
	}
	if duration > maxVideoDurationSeconds {
		return processedMedia{}, ErrMediaDurationTooLong
	}
	return processedMedia{data: raw, contentType: vc.contentType, extension: vc.extension}, nil
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

func NewMediaService(db MediaStore, store ObjectStore, maxBytes, maxVideoBytes int) *MediaService {
	return &MediaService{db: db, pipeline: newMediaPipeline(store, maxBytes, maxVideoBytes)}
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
