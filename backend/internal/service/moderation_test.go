package service

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"testing"
)

func TestFakeModerator_ModerateText(t *testing.T) {
	m := FakeModerator{}

	t.Run("safe turkish text is allowed", func(t *testing.T) {
		decision, err := m.ModerateText(context.Background(), "Sokak kedisi arka ayağından yaralı, yardım gerekiyor.")
		if err != nil {
			t.Fatalf("ModerateText: %v", err)
		}
		if !decision.Allowed {
			t.Errorf("expected allow, got reject with categories %v", decision.Categories)
		}
	})

	t.Run("benign cat name is allowed", func(t *testing.T) {
		decision, err := m.ModerateText(context.Background(), "Boncuk")
		if err != nil {
			t.Fatalf("ModerateText: %v", err)
		}
		if !decision.Allowed {
			t.Errorf("expected allow, got reject with categories %v", decision.Categories)
		}
	})

	t.Run("unsafe turkish text is rejected", func(t *testing.T) {
		text := "Bu bir test metni " + FakeModerationRejectMarker(ModerationCategoryHate)
		decision, err := m.ModerateText(context.Background(), text)
		if err != nil {
			t.Fatalf("ModerateText: %v", err)
		}
		if decision.Allowed {
			t.Fatal("expected reject")
		}
		if len(decision.Categories) != 1 || decision.Categories[0] != ModerationCategoryHate {
			t.Errorf("expected [hate], got %v", decision.Categories)
		}
	})

	t.Run("simulated provider failure fails closed", func(t *testing.T) {
		_, err := m.ModerateText(context.Background(), fakeModerationUnavailableTextTrigger)
		if !errors.Is(err, ErrModerationUnavailable) {
			t.Fatalf("expected ErrModerationUnavailable, got %v", err)
		}
	})

	t.Run("respects context cancellation", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, err := m.ModerateText(ctx, "irrelevant"); err == nil {
			t.Fatal("expected error for a cancelled context")
		}
	})
}

func TestFakeModerator_ModerateImage(t *testing.T) {
	m := FakeModerator{}

	t.Run("normal cat photo is allowed", func(t *testing.T) {
		decision, err := m.ModerateImage(context.Background(), "image/png", solidColorPNG(t, 800, 600))
		if err != nil {
			t.Fatalf("ModerateImage: %v", err)
		}
		if !decision.Allowed {
			t.Errorf("expected allow, got reject with categories %v", decision.Categories)
		}
	})

	t.Run("legitimate injured-cat welfare photo is allowed", func(t *testing.T) {
		decision, err := m.ModerateImage(context.Background(), "image/png", solidColorPNG(t, 4008, 4008))
		if err != nil {
			t.Fatalf("ModerateImage: %v", err)
		}
		if !decision.Allowed {
			t.Error("a welfare-documentation photo of an injured cat must not be rejected merely for showing the injury")
		}
	})

	t.Run("prohibited image is rejected", func(t *testing.T) {
		decision, err := m.ModerateImage(context.Background(), "image/png", solidColorPNG(t, 4001, 4001))
		if err != nil {
			t.Fatalf("ModerateImage: %v", err)
		}
		if decision.Allowed {
			t.Fatal("expected reject")
		}
		if len(decision.Categories) != 1 || decision.Categories[0] != ModerationCategorySexual {
			t.Errorf("expected [sexual], got %v", decision.Categories)
		}
	})

	t.Run("gratuitous animal cruelty is rejected", func(t *testing.T) {
		decision, err := m.ModerateImage(context.Background(), "image/png", solidColorPNG(t, 4007, 4007))
		if err != nil {
			t.Fatalf("ModerateImage: %v", err)
		}
		if decision.Allowed {
			t.Fatal("expected reject")
		}
	})

	t.Run("simulated provider failure fails closed", func(t *testing.T) {
		_, err := m.ModerateImage(context.Background(), "image/png", solidColorPNG(t, 4009, 4009))
		if !errors.Is(err, ErrModerationUnavailable) {
			t.Fatalf("expected ErrModerationUnavailable, got %v", err)
		}
	})

	t.Run("malformed image fails closed", func(t *testing.T) {
		_, err := m.ModerateImage(context.Background(), "image/png", []byte("not an image"))
		if !errors.Is(err, ErrModerationUnavailable) {
			t.Fatalf("expected ErrModerationUnavailable, got %v", err)
		}
	})
}

// solidColorPNG builds a deterministic width x height PNG fixture — PNG's
// lossless re-encode (see mediaPipeline.process) means these dimensions
// survive the full upload pipeline unchanged, unlike a lossy jpeg re-encode.
func solidColorPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	fill := color.RGBA{R: 120, G: 130, B: 140, A: 255}
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.Set(x, y, fill)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png.Encode: %v", err)
	}
	return buf.Bytes()
}
