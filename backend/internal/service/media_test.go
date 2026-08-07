package service

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"math/rand"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

func validJPEGBytes(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	for y := 0; y < 4; y++ {
		for x := 0; x < 4; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 10), G: uint8(y * 10), B: 100, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatalf("encode test jpeg: %v", err)
	}
	return buf.Bytes()
}

// lowQualityJPEGBytesThatReencodeLarger returns a small (quality=1) jpeg
// whose noisy pixel content re-encodes much larger at mediaPipeline's fixed
// quality=90 — a highly-compressed input can still expand well past the
// byte-size limit once re-encoded, so the size check must cover the
// *output*, not just what was uploaded.
func lowQualityJPEGBytesThatReencodeLarger(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 300, 300))
	r := rand.New(rand.NewSource(1))
	for y := range 300 {
		for x := range 300 {
			img.Set(x, y, color.RGBA{
				R: uint8(r.Intn(256)), G: uint8(r.Intn(256)), B: uint8(r.Intn(256)), A: 255,
			})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 1}); err != nil {
		t.Fatalf("encode low-quality test jpeg: %v", err)
	}
	return buf.Bytes()
}

func validPNGBytes(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode test png: %v", err)
	}
	return buf.Bytes()
}

// oversizedDimensionsPNGBytes returns a syntactically valid PNG signature
// plus a single IHDR chunk declaring width*height far beyond maxImagePixels
// — no IDAT/IEND at all. image.DecodeConfig (which the decompression-bomb
// guard in mediaPipeline.process must reject on) only ever needs the IHDR
// chunk for a non-paletted color type, so this is enough to exercise that
// check without materializing an actual multi-gigapixel pixel buffer.
func oversizedDimensionsPNGBytes(t *testing.T) []byte {
	t.Helper()
	// image/png's own decoder caps a declared dimension to positive int32
	// (see its parseIHDR — anything else is rejected as "non-positive
	// dimension" before mediaPipeline.process ever sees it), so the
	// largest input actually reachable through DecodeConfig is well short
	// of overflowing an int64 width*height product. 30000x30000 is enough
	// to clear maxImagePixels without relying on that ceiling.
	return pngBytesWithDimensions(t, 30000, 30000) // 900,000,000 px > maxImagePixels
}

func pngBytesWithDimensions(t *testing.T, width, height uint32) []byte {
	t.Helper()
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:4], width)
	binary.BigEndian.PutUint32(ihdr[4:8], height)
	ihdr[8] = 8  // bit depth
	ihdr[9] = 2  // color type: truecolor (non-paletted)
	ihdr[10] = 0 // compression method
	ihdr[11] = 0 // filter method
	ihdr[12] = 0 // interlace method

	var buf bytes.Buffer
	buf.Write([]byte("\x89PNG\r\n\x1a\n")) // png signature
	writePNGChunk(&buf, "IHDR", ihdr)
	return buf.Bytes()
}

func writePNGChunk(buf *bytes.Buffer, typ string, data []byte) {
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(data)))
	buf.Write(length[:])
	buf.Write([]byte(typ))
	buf.Write(data)
	crc := crc32.NewIEEE()
	crc.Write([]byte(typ))
	crc.Write(data)
	var sum [4]byte
	binary.BigEndian.PutUint32(sum[:], crc.Sum32())
	buf.Write(sum[:])
}

// mp4Bytes builds a minimal but structurally valid ISO-base-media-file
// fixture: an ftyp box declaring majorBrand, followed by a moov box
// containing just an mvhd box (version 0) with the given timescale/
// duration — enough for sniffVideoContainer and videoDurationSeconds to
// exercise their real box-walking logic without a real video file.
func mp4Bytes(t *testing.T, majorBrand string, timescale, duration uint32) []byte {
	t.Helper()
	if len(majorBrand) != 4 {
		t.Fatalf("majorBrand must be 4 bytes, got %q", majorBrand)
	}

	var ftyp bytes.Buffer
	writeUint32(&ftyp, 20)
	ftyp.WriteString("ftyp")
	ftyp.WriteString(majorBrand)
	writeUint32(&ftyp, 0)        // minor_version
	ftyp.WriteString(majorBrand) // compatible_brands (one entry)

	mvhdContent := make([]byte, 100) // version+flags+timestamps+timescale+duration, zero-padded
	mvhdContent[0] = 0               // version 0
	binary.BigEndian.PutUint32(mvhdContent[12:16], timescale)
	binary.BigEndian.PutUint32(mvhdContent[16:20], duration)

	var mvhd bytes.Buffer
	writeUint32(&mvhd, uint32(8+len(mvhdContent)))
	mvhd.WriteString("mvhd")
	mvhd.Write(mvhdContent)

	var moov bytes.Buffer
	writeUint32(&moov, uint32(8+mvhd.Len()))
	moov.WriteString("moov")
	moov.Write(mvhd.Bytes())

	var out bytes.Buffer
	out.Write(ftyp.Bytes())
	out.Write(moov.Bytes())
	return out.Bytes()
}

func writeUint32(buf *bytes.Buffer, v uint32) {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	buf.Write(b[:])
}

func TestSniffVideoContainer_RecognizesSupportedBrands(t *testing.T) {
	for brand, want := range videoMajorBrands {
		raw := mp4Bytes(t, brand, 1000, 1000)
		vc, ok := sniffVideoContainer(raw)
		if !ok {
			t.Errorf("brand %q: expected recognized container", brand)
			continue
		}
		if vc != want {
			t.Errorf("brand %q: got %+v, want %+v", brand, vc, want)
		}
	}
}

func TestSniffVideoContainer_RejectsUnknownBrandAndShortInput(t *testing.T) {
	if _, ok := sniffVideoContainer(mp4Bytes(t, "avc1", 1000, 1000)); ok {
		t.Error("expected unrecognized major_brand to be rejected")
	}
	if _, ok := sniffVideoContainer([]byte("short")); ok {
		t.Error("expected too-short input to be rejected")
	}
}

func TestVideoDurationSeconds_ParsesMvhd(t *testing.T) {
	raw := mp4Bytes(t, "isom", 1000, 30000)
	got, err := videoDurationSeconds(raw)
	if err != nil {
		t.Fatalf("videoDurationSeconds: %v", err)
	}
	if got != 30 {
		t.Errorf("expected 30s duration, got %v", got)
	}
}

func TestVideoDurationSeconds_RejectsMissingMoovOrZeroTimescale(t *testing.T) {
	if _, err := videoDurationSeconds(mp4Bytes(t, "isom", 1000, 30000)[:20]); !errors.Is(err, ErrMalformedMedia) {
		t.Errorf("expected ErrMalformedMedia for missing moov, got %v", err)
	}
	if _, err := videoDurationSeconds(mp4Bytes(t, "isom", 0, 30000)); !errors.Is(err, ErrMalformedMedia) {
		t.Errorf("expected ErrMalformedMedia for zero timescale, got %v", err)
	}
}

func TestMediaPipeline_ProcessVideo_AcceptsWithinLimits(t *testing.T) {
	p := newMediaPipeline(&fakeObjectStore{}, 1<<20, 1<<20)
	raw := mp4Bytes(t, "isom", 1000, 30000) // exactly the 30s cap
	result, err := p.process(raw)
	if err != nil {
		t.Fatalf("process: %v", err)
	}
	if result.contentType != "video/mp4" || result.extension != "mp4" {
		t.Errorf("unexpected result: %+v", result)
	}
	if !bytes.Equal(result.data, raw) {
		t.Error("expected video bytes to be stored unmodified (no transcoding)")
	}
}

func TestMediaPipeline_ProcessVideo_RejectsTooLong(t *testing.T) {
	p := newMediaPipeline(&fakeObjectStore{}, 1<<20, 1<<20)
	raw := mp4Bytes(t, "isom", 1000, 30001) // just over the 30s cap
	if _, err := p.process(raw); !errors.Is(err, ErrMediaDurationTooLong) {
		t.Errorf("expected ErrMediaDurationTooLong, got %v", err)
	}
}

func TestMediaPipeline_ProcessVideo_RejectsOversized(t *testing.T) {
	raw := mp4Bytes(t, "isom", 1000, 5000)
	p := newMediaPipeline(&fakeObjectStore{}, 1<<20, len(raw)-1)
	if _, err := p.process(raw); !errors.Is(err, ErrMediaTooLarge) {
		t.Errorf("expected ErrMediaTooLarge, got %v", err)
	}
}

func TestMediaPipeline_Process_RejectsVideoWhenVideoDisabled(t *testing.T) {
	// maxVideoBytes == 0 (CatsService's pipeline, issue #153: a cat's own
	// initial photo stays image-only) must never route into processVideo.
	p := newMediaPipeline(&fakeObjectStore{}, 1<<20, 0)
	raw := mp4Bytes(t, "isom", 1000, 5000)
	if _, err := p.process(raw); !errors.Is(err, ErrMalformedMedia) {
		t.Errorf("expected the video to fall through to image decoding and fail as ErrMalformedMedia, got %v", err)
	}
}

// fakeObjectStore is a minimal in-memory ObjectStore for tests that don't
// need FakeObjectStore's real disk i/o — just call-capturing.
type fakeObjectStore struct {
	putErr    error
	deleteErr error

	puts    []string
	deletes []string
}

func (f *fakeObjectStore) Put(_ context.Context, key, _ string, _ []byte) (string, error) {
	f.puts = append(f.puts, key)
	if f.putErr != nil {
		return "", f.putErr
	}
	return "/v1/media/objects/" + key, nil
}

func (f *fakeObjectStore) Delete(_ context.Context, key string) error {
	f.deletes = append(f.deletes, key)
	return f.deleteErr
}

type fakeMediaStore struct {
	createRow repository.Medium
	createErr error
	// captured, if non-nil, records the arg the last CreateMedia call
	// received.
	captured *repository.CreateMediaParams

	idempotencyRow repository.Medium
	idempotencyErr error
}

func (f *fakeMediaStore) CreateMedia(_ context.Context, arg repository.CreateMediaParams) (repository.Medium, error) {
	if f.captured != nil {
		*f.captured = arg
	}
	return f.createRow, f.createErr
}

func (f *fakeMediaStore) GetMediaByIdempotencyKey(_ context.Context, _ repository.GetMediaByIdempotencyKeyParams) (repository.Medium, error) {
	return f.idempotencyRow, f.idempotencyErr
}

func TestMediaPipeline_Process_RejectsEmpty(t *testing.T) {
	p := newMediaPipeline(&fakeObjectStore{}, 1024, 0)
	if _, err := p.process(nil); !errors.Is(err, ErrMalformedMedia) {
		t.Errorf("expected ErrMalformedMedia, got %v", err)
	}
}

func TestMediaPipeline_Process_RejectsOversized(t *testing.T) {
	p := newMediaPipeline(&fakeObjectStore{}, 4, 0)
	if _, err := p.process([]byte("way too big")); !errors.Is(err, ErrMediaTooLarge) {
		t.Errorf("expected ErrMediaTooLarge, got %v", err)
	}
}

func TestMediaPipeline_Process_RejectsMalformed(t *testing.T) {
	p := newMediaPipeline(&fakeObjectStore{}, 1<<20, 0)
	if _, err := p.process([]byte("not an image, just text pretending to be one")); !errors.Is(err, ErrMalformedMedia) {
		t.Errorf("expected ErrMalformedMedia, got %v", err)
	}
}

// TestMediaPipeline_Process_RejectsOversizedDimensions guards against a
// decompression bomb: a small file whose declared dimensions would still
// force allocating an enormous pixel buffer on a full image.Decode. The
// check must reject via image.DecodeConfig (header only) before ever
// calling image.Decode.
func TestMediaPipeline_Process_RejectsOversizedDimensions(t *testing.T) {
	p := newMediaPipeline(&fakeObjectStore{}, 1<<20, 0)
	if _, err := p.process(oversizedDimensionsPNGBytes(t)); !errors.Is(err, ErrMediaDimensionsTooLarge) {
		t.Errorf("expected ErrMediaDimensionsTooLarge, got %v", err)
	}
}

// TestMediaPipeline_Process_RejectsWhenReencodedOutputExceedsMaxBytes proves
// the byte-size limit covers what actually gets stored (the re-encoded
// output), not just what was uploaded — a highly-compressed input can
// still pass the initial len(raw) check and then expand once decoded and
// re-encoded at mediaPipeline's fixed quality. The exact growth ratio is a
// stdlib jpeg-encoder implementation detail, so this derives the boundary
// from an actual unbounded process() call instead of hardcoding byte counts.
func TestMediaPipeline_Process_RejectsWhenReencodedOutputExceedsMaxBytes(t *testing.T) {
	raw := lowQualityJPEGBytesThatReencodeLarger(t)

	unbounded := newMediaPipeline(&fakeObjectStore{}, 1<<20, 0)
	processed, err := unbounded.process(raw)
	if err != nil {
		t.Fatalf("process with no effective limit: %v", err)
	}
	if len(processed.data) <= len(raw) {
		t.Fatalf("test fixture assumption broken: re-encoded output (%d bytes) is not larger than raw input (%d bytes)", len(processed.data), len(raw))
	}

	// A limit between the two sizes clears len(raw) but not the re-encoded
	// output.
	maxBytes := (len(raw) + len(processed.data)) / 2
	bounded := newMediaPipeline(&fakeObjectStore{}, maxBytes, 0)
	if _, err := bounded.process(raw); !errors.Is(err, ErrMediaTooLarge) {
		t.Errorf("expected ErrMediaTooLarge for an oversized re-encoded output, got %v", err)
	}
}

func TestMediaPipeline_Process_AcceptsJPEGAndPNG(t *testing.T) {
	p := newMediaPipeline(&fakeObjectStore{}, 1<<20, 0)

	jpegResult, err := p.process(validJPEGBytes(t))
	if err != nil {
		t.Fatalf("process jpeg: %v", err)
	}
	if jpegResult.contentType != "image/jpeg" || jpegResult.extension != "jpg" {
		t.Errorf("unexpected jpeg result: %+v", jpegResult)
	}

	pngResult, err := p.process(validPNGBytes(t))
	if err != nil {
		t.Fatalf("process png: %v", err)
	}
	if pngResult.contentType != "image/png" || pngResult.extension != "png" {
		t.Errorf("unexpected png result: %+v", pngResult)
	}
}

func TestMediaService_Upload_HappyPath(t *testing.T) {
	store := &fakeObjectStore{}
	mediaStore := &fakeMediaStore{
		createRow: repository.Medium{
			ID:  pgtype.UUID{Bytes: [16]byte{1}, Valid: true},
			Url: "/v1/media/objects/generated.jpg",
		},
		idempotencyErr: pgx.ErrNoRows,
	}
	svc := NewMediaService(mediaStore, store, 1<<20, 1<<20)

	media, err := svc.Upload(context.Background(), userIDFor(t), "", nil, validJPEGBytes(t))
	if err != nil {
		t.Fatalf("Upload: %v", err)
	}
	if media.URL != "/v1/media/objects/generated.jpg" {
		t.Errorf("unexpected url: %q", media.URL)
	}
	if len(store.puts) != 1 {
		t.Errorf("expected exactly one object stored, got %d", len(store.puts))
	}
	if len(store.deletes) != 0 {
		t.Errorf("expected no compensating delete on success, got %v", store.deletes)
	}
}

func TestMediaService_Upload_IdempotentRetryReturnsExisting(t *testing.T) {
	store := &fakeObjectStore{}
	existing := repository.Medium{
		ID:  pgtype.UUID{Bytes: [16]byte{2}, Valid: true},
		Url: "/v1/media/objects/existing.jpg",
	}
	mediaStore := &fakeMediaStore{idempotencyRow: existing}
	svc := NewMediaService(mediaStore, store, 1<<20, 1<<20)

	key := "retry-key"
	media, err := svc.Upload(context.Background(), userIDFor(t), "", &key, validJPEGBytes(t))
	if err != nil {
		t.Fatalf("Upload: %v", err)
	}
	if media.URL != existing.Url {
		t.Errorf("expected existing media returned, got %+v", media)
	}
	if len(store.puts) != 0 {
		t.Errorf("expected no upload on idempotent hit, got %v", store.puts)
	}
}

func TestMediaService_Upload_CompensatesOnDBFailure(t *testing.T) {
	store := &fakeObjectStore{}
	mediaStore := &fakeMediaStore{
		createErr:      errors.New("db exploded"),
		idempotencyErr: pgx.ErrNoRows,
	}
	svc := NewMediaService(mediaStore, store, 1<<20, 1<<20)

	if _, err := svc.Upload(context.Background(), userIDFor(t), "", nil, validJPEGBytes(t)); err == nil {
		t.Fatal("expected error")
	}
	if len(store.puts) != 1 {
		t.Fatalf("expected the object to have been uploaded once, got %v", store.puts)
	}
	if len(store.deletes) != 1 || store.deletes[0] != store.puts[0] {
		t.Errorf("expected the uploaded object to be compensated (deleted), got puts=%v deletes=%v", store.puts, store.deletes)
	}
}

func TestMediaService_Upload_RaceOnIdempotencyKeyRecoversExisting(t *testing.T) {
	// Simulates two concurrent requests with the same idempotency key: the
	// initial GetMediaByIdempotencyKey lookup misses (ErrNoRows) for both,
	// but by the time this request's CreateMedia runs, the other one already
	// committed — surfacing as CreateMedia itself returning ErrNoRows (the
	// on-conflict-do-nothing path, see db/queries/media.sql).
	store := &fakeObjectStore{}
	existing := repository.Medium{
		ID:  pgtype.UUID{Bytes: [16]byte{3}, Valid: true},
		Url: "/v1/media/objects/won-the-race.jpg",
	}
	mediaStore := &fakeMediaStore{
		createErr:      pgx.ErrNoRows,
		idempotencyErr: nil,
		idempotencyRow: existing,
	}

	key := "race-key"
	// First lookup (before upload) must miss for Upload to even attempt a
	// create; simulate that by having idempotencyErr flip after the first
	// call using a tiny stateful wrapper.
	firstCall := true
	wrapped := &statefulMediaStore{
		fakeMediaStore: mediaStore,
		onGetIdempotency: func() (repository.Medium, error) {
			if firstCall {
				firstCall = false
				return repository.Medium{}, pgx.ErrNoRows
			}
			return existing, nil
		},
	}
	svc := NewMediaService(wrapped, store, 1<<20, 1<<20)

	media, err := svc.Upload(context.Background(), userIDFor(t), "", &key, validJPEGBytes(t))
	if err != nil {
		t.Fatalf("Upload: %v", err)
	}
	if media.URL != existing.Url {
		t.Errorf("expected the concurrently-created row to be returned, got %+v", media)
	}
	if len(store.deletes) != 1 {
		t.Errorf("expected this attempt's own upload to be cleaned up, got %v", store.deletes)
	}
}

// statefulMediaStore lets a test vary GetMediaByIdempotencyKey's answer
// across calls (first miss, then hit) without a full mock framework.
type statefulMediaStore struct {
	*fakeMediaStore
	onGetIdempotency func() (repository.Medium, error)
}

func (s *statefulMediaStore) GetMediaByIdempotencyKey(_ context.Context, _ repository.GetMediaByIdempotencyKeyParams) (repository.Medium, error) {
	return s.onGetIdempotency()
}

// userIDFor returns a well-formed uuid string, since MediaService.Upload
// parses userID as a uuid before doing anything else.
func userIDFor(t *testing.T) string {
	t.Helper()
	return "11111111-1111-4111-8111-111111111111"
}
