package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/draw"
	"image/jpeg"
	_ "image/png" // decode support for ffmpeg's png frame output
	"os"
	"os/exec"
	"time"
)

// contactSheetFrameCount is the fixed number of frames issue #241 requires
// ("sample exactly 3 deterministic frames: near start, middle, and near
// end") — never configurable per-request.
const contactSheetFrameCount = 3

// contactSheetFrameFractions are the fixed fractional offsets (of the
// video's own duration) each contact-sheet frame is sampled at — near
// start, middle, near end, in that fixed order, matching
// contactSheetFrameCount.
var contactSheetFrameFractions = [contactSheetFrameCount]float64{0.05, 0.5, 0.95}

// FrameExtractor produces one contact-sheet still image from a video, for
// pre-publication vision moderation (issue #241). Kept as its own interface
// — separate from Moderator — so a test can substitute a fake contact sheet
// without depending on the ffmpeg binary FFmpegFrameExtractor shells out to;
// the resulting contact sheet is then classified through the ordinary
// Moderator.ModerateImage path (see mediaPipeline's video moderation call
// site in media.go), never a separate video-moderation method.
type FrameExtractor interface {
	// ExtractContactSheet returns one jpeg contact-sheet image combining
	// contactSheetFrameCount frames sampled from video (already validated,
	// narrow-format container bytes — see sniffVideoContainer/
	// videoDurationSeconds). Any failure (corrupt video, ffmpeg unavailable,
	// decode failure) fails closed for the upload in progress (issue #241:
	// "frame extraction or moderation failure fails closed for that
	// upload") — callers never store or publish on an extraction error.
	ExtractContactSheet(ctx context.Context, video []byte, extension string) ([]byte, error)
}

// FFmpegFrameExtractor shells out to the ffmpeg binary (issue #241: "this is
// an intentional 0.4 deploy/runtime dependency rather than a new worker
// service") once per contact-sheet frame to pull a single still at a fixed
// fractional offset of the video's own duration, then composes the frames
// side-by-side into one jpeg in pure Go (composeContactSheet) — ffmpeg's own
// job stays deliberately narrow (single-frame extraction only), so the
// composition step stays unit-testable without the binary at all.
type FFmpegFrameExtractor struct {
	binary  string
	timeout time.Duration
}

// FFmpegFrameExtractorOption configures optional FFmpegFrameExtractor
// behavior.
type FFmpegFrameExtractorOption func(*FFmpegFrameExtractor)

// WithFFmpegBinary overrides the ffmpeg executable name/path — tests point
// it at a stub script so they don't depend on a real ffmpeg install.
func WithFFmpegBinary(path string) FFmpegFrameExtractorOption {
	return func(e *FFmpegFrameExtractor) { e.binary = path }
}

// WithFFmpegTimeout overrides the per-frame extraction timeout.
func WithFFmpegTimeout(d time.Duration) FFmpegFrameExtractorOption {
	return func(e *FFmpegFrameExtractor) { e.timeout = d }
}

// NewFFmpegFrameExtractor constructs an extractor that shells out to the
// named binary ("ffmpeg" by default — resolved via PATH at call time, not
// validated here: issue #241 rules out a live check during startup, and
// running ffmpeg isn't one anyway).
func NewFFmpegFrameExtractor(opts ...FFmpegFrameExtractorOption) *FFmpegFrameExtractor {
	e := &FFmpegFrameExtractor{binary: "ffmpeg", timeout: 10 * time.Second}
	for _, opt := range opts {
		opt(e)
	}
	return e
}

// ExtractContactSheet implements FrameExtractor.
func (e *FFmpegFrameExtractor) ExtractContactSheet(ctx context.Context, video []byte, extension string) ([]byte, error) {
	duration, err := videoDurationSeconds(video)
	if err != nil {
		return nil, err
	}
	if duration <= 0 {
		return nil, ErrMalformedMedia
	}

	tmp, err := os.CreateTemp("", "moderation-video-*."+extension)
	if err != nil {
		return nil, fmt.Errorf("frame extractor: create temp file: %w", err)
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(video); err != nil {
		_ = tmp.Close()
		return nil, fmt.Errorf("frame extractor: write temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return nil, fmt.Errorf("frame extractor: close temp file: %w", err)
	}

	frames := make([]image.Image, 0, contactSheetFrameCount)
	for _, fraction := range contactSheetFrameFractions {
		offset := time.Duration(fraction * duration * float64(time.Second))
		img, err := e.extractFrame(ctx, tmp.Name(), offset)
		if err != nil {
			return nil, err
		}
		frames = append(frames, img)
	}
	return composeContactSheet(frames)
}

// extractFrame runs one bounded ffmpeg invocation that seeks to offset and
// writes exactly one decoded png frame to stdout — no intermediate output
// file, so nothing beyond the input temp file needs cleanup.
func (e *FFmpegFrameExtractor) extractFrame(ctx context.Context, path string, offset time.Duration) (image.Image, error) {
	reqCtx, cancel := context.WithTimeout(ctx, e.timeout)
	defer cancel()

	cmd := exec.CommandContext(reqCtx, e.binary,
		"-ss", fmt.Sprintf("%.3f", offset.Seconds()),
		"-i", path,
		"-frames:v", "1",
		"-f", "image2pipe",
		"-vcodec", "png",
		"-",
	)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("frame extractor: ffmpeg failed: %w", err)
	}

	img, _, err := image.Decode(bytes.NewReader(stdout.Bytes()))
	if err != nil {
		return nil, fmt.Errorf("frame extractor: decode frame: %w", err)
	}
	return img, nil
}

// composeContactSheet lays frames out side-by-side at the first frame's
// height and re-encodes the result as one jpeg — pure Go, no ffmpeg
// dependency, so this step alone is unit-testable without the binary.
// Exported at package scope (lowercase, same-package tests only) rather than
// a method: it has no dependency on FFmpegFrameExtractor's own state.
func composeContactSheet(frames []image.Image) ([]byte, error) {
	if len(frames) == 0 {
		return nil, errors.New("frame extractor: no frames to compose")
	}
	height := frames[0].Bounds().Dy()
	totalWidth := 0
	for _, f := range frames {
		totalWidth += f.Bounds().Dx()
	}

	sheet := image.NewRGBA(image.Rect(0, 0, totalWidth, height))
	x := 0
	for _, f := range frames {
		b := f.Bounds()
		draw.Draw(sheet, image.Rect(x, 0, x+b.Dx(), height), f, b.Min, draw.Src)
		x += b.Dx()
	}

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, sheet, &jpeg.Options{Quality: 85}); err != nil {
		return nil, fmt.Errorf("frame extractor: encode contact sheet: %w", err)
	}
	return buf.Bytes(), nil
}
