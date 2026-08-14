package service

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestComposeContactSheet_LaysFramesSideBySide covers the pure-Go
// composition step in isolation, with no dependency on the ffmpeg binary —
// three same-height frames of known widths must compose into one sheet
// whose width is their sum and whose height matches the first frame.
func TestComposeContactSheet_LaysFramesSideBySide(t *testing.T) {
	frames := []image.Image{
		solidImage(t, 10, 20, color.RGBA{R: 255, A: 255}),
		solidImage(t, 30, 20, color.RGBA{G: 255, A: 255}),
		solidImage(t, 15, 20, color.RGBA{B: 255, A: 255}),
	}

	sheetBytes, err := composeContactSheet(frames)
	if err != nil {
		t.Fatalf("composeContactSheet: %v", err)
	}

	decoded, _, err := image.Decode(bytes.NewReader(sheetBytes))
	if err != nil {
		t.Fatalf("decode composed sheet: %v", err)
	}
	b := decoded.Bounds()
	if b.Dx() != 10+30+15 {
		t.Errorf("expected width 55, got %d", b.Dx())
	}
	if b.Dy() != 20 {
		t.Errorf("expected height 20, got %d", b.Dy())
	}
}

func TestComposeContactSheet_RejectsEmptyFrameList(t *testing.T) {
	if _, err := composeContactSheet(nil); err == nil {
		t.Fatal("expected error composing zero frames")
	}
}

// TestFFmpegFrameExtractor_ExtractsThreeFramesAndComposes uses a stub
// "ffmpeg" script instead of a real install (this sandbox/ci may not have
// one) so the test stays deterministic: it exercises the real
// FFmpegFrameExtractor orchestration (building the -ss/-i argv, capturing
// stdout, decoding, and composing) end to end, and separately proves it
// samples the fixed near-start/middle/near-end offsets issue #241 requires.
func TestFFmpegFrameExtractor_ExtractsThreeFramesAndComposes(t *testing.T) {
	dir := t.TempDir()
	stubPath := writeFFmpegStub(t, dir, solidColorPNGBytesFor(t, 8, 6))

	extractor := NewFFmpegFrameExtractor(WithFFmpegBinary(stubPath))
	video := mp4Bytes(t, "isom", 1000, 10000) // 10s duration

	sheet, err := extractor.ExtractContactSheet(context.Background(), video, "mp4")
	if err != nil {
		t.Fatalf("ExtractContactSheet: %v", err)
	}

	decoded, _, err := image.Decode(bytes.NewReader(sheet))
	if err != nil {
		t.Fatalf("decode contact sheet: %v", err)
	}
	if got, want := decoded.Bounds().Dx(), 8*contactSheetFrameCount; got != want {
		t.Errorf("expected composed width %d, got %d", want, got)
	}

	calls := readFFmpegStubCalls(t, dir)
	if len(calls) != contactSheetFrameCount {
		t.Fatalf("expected %d ffmpeg invocations, got %d: %v", contactSheetFrameCount, len(calls), calls)
	}
	wantOffsets := []string{"0.500", "5.000", "9.500"} // 10s * {0.05, 0.5, 0.95}
	for i, want := range wantOffsets {
		if !strings.Contains(calls[i], "-ss "+want) {
			t.Errorf("call %d: expected -ss %s, got %q", i, want, calls[i])
		}
	}
}

func TestFFmpegFrameExtractor_RejectsMalformedVideo(t *testing.T) {
	extractor := NewFFmpegFrameExtractor(WithFFmpegBinary("/does/not/matter"))
	if _, err := extractor.ExtractContactSheet(context.Background(), []byte("not a video"), "mp4"); err == nil {
		t.Fatal("expected error for malformed video (no valid moov/mvhd)")
	}
}

func TestFFmpegFrameExtractor_FailsClosedWhenBinaryMissing(t *testing.T) {
	extractor := NewFFmpegFrameExtractor(WithFFmpegBinary(filepath.Join(t.TempDir(), "no-such-ffmpeg")))
	video := mp4Bytes(t, "isom", 1000, 10000)
	if _, err := extractor.ExtractContactSheet(context.Background(), video, "mp4"); err == nil {
		t.Fatal("expected error when the ffmpeg binary can't be found")
	}
}

func solidImage(t *testing.T, width, height int, fill color.RGBA) image.Image {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.Set(x, y, fill)
		}
	}
	return img
}

func solidColorPNGBytesFor(t *testing.T, width, height int) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, solidImage(t, width, height, color.RGBA{R: 10, G: 20, B: 30, A: 255})); err != nil {
		t.Fatalf("png.Encode: %v", err)
	}
	return buf.Bytes()
}

// writeFFmpegStub writes an executable shell script standing in for the
// ffmpeg binary: it appends its own argv to calls.log (one line per
// invocation) in dir, then writes frame to stdout — mirroring real ffmpeg's
// "-f image2pipe -vcodec png -" contract closely enough for this
// extractor's own decode step to succeed.
func writeFFmpegStub(t *testing.T, dir string, frame []byte) string {
	t.Helper()
	framePath := filepath.Join(dir, "frame.png")
	if err := os.WriteFile(framePath, frame, 0o644); err != nil {
		t.Fatalf("write frame fixture: %v", err)
	}
	logPath := filepath.Join(dir, "calls.log")
	stubPath := filepath.Join(dir, "ffmpeg-stub.sh")
	script := "#!/bin/sh\n" +
		"echo \"$*\" >> " + logPath + "\n" +
		"cat " + framePath + "\n"
	if err := os.WriteFile(stubPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write ffmpeg stub: %v", err)
	}
	return stubPath
}

func readFFmpegStubCalls(t *testing.T, dir string) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "calls.log"))
	if err != nil {
		t.Fatalf("read calls.log: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	var out []string
	for _, l := range lines {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}
