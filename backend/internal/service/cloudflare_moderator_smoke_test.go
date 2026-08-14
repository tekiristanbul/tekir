//go:build cloudflare_smoke

// The manually-triggered smoke suite issue #241 makes a release gate: it is
// the only thing that exercises the real Workers AI request and response
// shapes. Everything in normal ci runs against the deterministic fake, which
// by construction cannot catch a wrong field name, a wrong model slug, or a
// model that answers in a shape this adapter does not read — the failure
// mode being guarded against is a provider integration that is green in ci
// and rejects every write in production.
//
// It is behind a build tag so `go test ./...` never reaches it: it costs real
// inference calls and needs credentials.
//
//	make smoke-cloudflare
//
// or directly:
//
//	CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=... \
//	  go test -tags cloudflare_smoke -run Smoke -v ./internal/service/
//
// MODERATION_TEXT_MODEL / MODERATION_VISION_MODEL override the models; they
// default to the ones the deployment config uses.

package service_test

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"testing"
	"time"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

const (
	defaultSmokeTextModel   = "@cf/google/gemma-4-26b-a4b-it"
	defaultSmokeVisionModel = "@cf/moondream/moondream3.1-9B-A2B"
)

func newSmokeModerator(t *testing.T) *service.CloudflareModerator {
	t.Helper()
	accountID := os.Getenv("CLOUDFLARE_ACCOUNT_ID")
	apiToken := os.Getenv("CLOUDFLARE_API_TOKEN")
	if accountID == "" || apiToken == "" {
		t.Skip("CLOUDFLARE_ACCOUNT_ID/CLOUDFLARE_API_TOKEN not set")
	}

	textModel := os.Getenv("MODERATION_TEXT_MODEL")
	if textModel == "" {
		textModel = defaultSmokeTextModel
	}
	visionModel := os.Getenv("MODERATION_VISION_MODEL")
	if visionModel == "" {
		visionModel = defaultSmokeVisionModel
	}

	m, err := service.NewCloudflareModerator(accountID, apiToken, textModel, visionModel)
	if err != nil {
		t.Fatalf("construct moderator: %v", err)
	}
	return m
}

// The product's primary language is Turkish, so the safe/unsafe pair is
// Turkish: a model that only reasons well in English would pass an
// English-only check and then mis-handle everything real users write.
func TestSmoke_TextModeration(t *testing.T) {
	m := newSmokeModerator(t)

	cases := []struct {
		name        string
		text        string
		wantAllowed bool
	}{
		{
			name:        "ordinary street-cat update",
			text:        "Sokak kedisi Boncuk bugün mama yedi, çok mutlu görünüyordu.",
			wantAllowed: true,
		},
		{
			name: "welfare report with a visible injury, which must stay allowed",
			text: "Kedinin ön patisinde yara var, kanıyor. Yardım edebilecek biri " +
				"varsa Galata civarında.",
			wantAllowed: true,
		},
		{
			name:        "threat against an animal",
			text:        "Bu kediyi bulup öldüreceğim, adresini bilen yazsın.",
			wantAllowed: false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()

			start := time.Now()
			decision, err := m.ModerateText(ctx, c.text)
			elapsed := time.Since(start)
			if err != nil {
				t.Fatalf("ModerateText: %v", err)
			}
			// Latency is reported rather than asserted: it sits inside the
			// user's own publish request, so a regression here is a product
			// problem, but a hard threshold would make the gate flaky.
			t.Logf("decision=%v categories=%v latency=%s", decision.Allowed, decision.Categories, elapsed)

			if decision.Allowed != c.wantAllowed {
				t.Errorf("allowed: want %v, got %v (categories %v)", c.wantAllowed, decision.Allowed, decision.Categories)
			}
		})
	}
}

// Proves the vision request shape and the response field this adapter reads.
// A flat grey jpeg is deliberately unremarkable: the assertion is that the
// call round-trips into a parseable decision, not that the model has an
// opinion about grey.
func TestSmoke_ImageModeration(t *testing.T) {
	m := newSmokeModerator(t)

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	start := time.Now()
	decision, err := m.ModerateImage(ctx, "image/jpeg", smokeJPEG(t, 640, 480))
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("ModerateImage: %v", err)
	}
	t.Logf("decision=%v categories=%v latency=%s", decision.Allowed, decision.Categories, elapsed)

	if !decision.Allowed {
		t.Errorf("a featureless grey image was rejected as %v", decision.Categories)
	}
}

// The contact sheet a video is moderated through is the same jpeg path, at a
// larger size — worth its own call, since request-size limits are the kind of
// thing that only shows up against the real endpoint.
func TestSmoke_ContactSheetSizedImage(t *testing.T) {
	m := newSmokeModerator(t)

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	sheet := smokeJPEG(t, 1920, 480)
	t.Logf("contact sheet bytes=%d", len(sheet))

	start := time.Now()
	decision, err := m.ModerateImage(ctx, "image/jpeg", sheet)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("ModerateImage (contact sheet): %v", err)
	}
	t.Logf("decision=%v categories=%v latency=%s", decision.Allowed, decision.Categories, elapsed)
}

func smokeJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	grey := color.RGBA{R: 128, G: 128, B: 128, A: 255}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, grey)
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatalf("encode smoke jpeg: %v", err)
	}
	return buf.Bytes()
}
