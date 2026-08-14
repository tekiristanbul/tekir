package service_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

const (
	testCloudflareAccountID   = "test-account-id"
	testCloudflareAPIToken    = "test-api-token-value"
	testCloudflareTextModel   = "@cf/google/gemma-4-26b-a4b-it"
	testCloudflareVisionModel = "@cf/moondream/moondream3.1-9B-A2B"
)

func newTestCloudflareModerator(t *testing.T, baseURL string, opts ...service.CloudflareModeratorOption) *service.CloudflareModerator {
	t.Helper()
	opts = append([]service.CloudflareModeratorOption{
		service.WithCloudflareModerationAPIBase(baseURL),
		service.WithCloudflareModerationRetryDelay(0),
	}, opts...)
	m, err := service.NewCloudflareModerator(testCloudflareAccountID, testCloudflareAPIToken, testCloudflareTextModel, testCloudflareVisionModel, opts...)
	if err != nil {
		t.Fatalf("NewCloudflareModerator: %v", err)
	}
	return m
}

// cloudflareEnvelope builds a Workers AI success envelope carrying reply as
// the model's own raw text output — see cloudflareRunResult's field-name
// fallback.
func cloudflareEnvelope(reply string) []byte {
	body, _ := json.Marshal(map[string]any{
		"success": true,
		"errors":  []any{},
		"result":  map[string]string{"response": reply},
	})
	return body
}

func TestCloudflareModerator_ModerateText_Allow(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer "+testCloudflareAPIToken {
			t.Errorf("unexpected authorization header: %q", got)
		}
		w.Write(cloudflareEnvelope(`{"decision":"allow","categories":[]}`))
	}))
	defer srv.Close()

	m := newTestCloudflareModerator(t, srv.URL)
	decision, err := m.ModerateText(context.Background(), "Boncuk")
	if err != nil {
		t.Fatalf("ModerateText: %v", err)
	}
	if !decision.Allowed {
		t.Errorf("expected allow, got reject with categories %v", decision.Categories)
	}
}

func TestCloudflareModerator_ModerateText_Reject(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(cloudflareEnvelope(`{"decision":"reject","categories":["hate"]}`))
	}))
	defer srv.Close()

	m := newTestCloudflareModerator(t, srv.URL)
	decision, err := m.ModerateText(context.Background(), "irrelevant")
	if err != nil {
		t.Fatalf("ModerateText: %v", err)
	}
	if decision.Allowed {
		t.Fatal("expected reject")
	}
	if len(decision.Categories) != 1 || decision.Categories[0] != service.ModerationCategoryHate {
		t.Errorf("expected [hate], got %v", decision.Categories)
	}
}

// TestCloudflareModerator_MalformedResultFailsClosed covers issue #241's
// "malformed model output ... fails closed" requirement at every layer: an
// envelope that isn't valid json, one with success=false, one whose result
// carries no recognizable text field, and a model reply that isn't the
// strict decision/categories json this package's prompts require.
func TestCloudflareModerator_MalformedResultFailsClosed(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"not json", `not json at all`},
		{"success false", `{"success":false,"errors":[{"code":1,"message":"boom"}]}`},
		{"empty result", `{"success":true,"errors":[],"result":{}}`},
		{"reply not json", `{"success":true,"errors":[],"result":{"response":"sure, this looks safe"}}`},
		{"reply missing decision", `{"success":true,"errors":[],"result":{"response":"{\"categories\":[]}"}}`},
		{"reply unknown category", `{"success":true,"errors":[],"result":{"response":"{\"decision\":\"reject\",\"categories\":[\"spam\"]}"}}`},
		{"reject with no categories", `{"success":true,"errors":[],"result":{"response":"{\"decision\":\"reject\",\"categories\":[]}"}}`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Write([]byte(tc.body))
			}))
			defer srv.Close()

			m := newTestCloudflareModerator(t, srv.URL)
			_, err := m.ModerateText(context.Background(), "irrelevant")
			if !errors.Is(err, service.ErrModerationUnavailable) {
				t.Fatalf("expected ErrModerationUnavailable, got %v", err)
			}
		})
	}
}

func TestCloudflareModerator_RetriesTransientFailures(t *testing.T) {
	for _, status := range []int{http.StatusInternalServerError, http.StatusServiceUnavailable, http.StatusTooManyRequests} {
		var attempts atomic.Int32
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			if attempts.Add(1) == 1 {
				w.WriteHeader(status)
				return
			}
			w.Write(cloudflareEnvelope(`{"decision":"allow","categories":[]}`))
		}))

		m := newTestCloudflareModerator(t, srv.URL)
		_, err := m.ModerateText(context.Background(), "irrelevant")
		if err != nil {
			t.Errorf("status %d: expected retry to succeed, got %v", status, err)
		}
		if got := attempts.Load(); got != 2 {
			t.Errorf("status %d: expected 2 attempts, got %d", status, got)
		}
		srv.Close()
	}
}

func TestCloudflareModerator_RetryIsBounded(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	m := newTestCloudflareModerator(t, srv.URL)
	if _, err := m.ModerateText(context.Background(), "irrelevant"); !errors.Is(err, service.ErrModerationUnavailable) {
		t.Fatalf("expected ErrModerationUnavailable, got %v", err)
	}
	if got := attempts.Load(); got != 2 {
		t.Errorf("expected exactly 2 attempts, got %d", got)
	}
}

func TestCloudflareModerator_PermanentFailureNotRetried(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer srv.Close()

	m := newTestCloudflareModerator(t, srv.URL)
	if _, err := m.ModerateText(context.Background(), "irrelevant"); !errors.Is(err, service.ErrModerationUnavailable) {
		t.Fatalf("expected ErrModerationUnavailable, got %v", err)
	}
	if got := attempts.Load(); got != 1 {
		t.Errorf("expected a single attempt, got %d", got)
	}
}

// TestCloudflareModerator_AuthFailureIsRedacted proves neither the returned
// error nor the log output leaks the api token.
func TestCloudflareModerator_AuthFailureIsRedacted(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()

	var logBuf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logBuf, nil))
	m := newTestCloudflareModerator(t, srv.URL, service.WithCloudflareModerationLogger(logger))

	_, err := m.ModerateText(context.Background(), "irrelevant")
	if !errors.Is(err, service.ErrModerationUnavailable) {
		t.Fatalf("expected ErrModerationUnavailable, got %v", err)
	}
	logged := logBuf.String()
	if strings.Contains(logged, testCloudflareAPIToken) {
		t.Errorf("log output leaks the api token: %q", logged)
	}
	if strings.Contains(err.Error(), testCloudflareAPIToken) {
		t.Errorf("error leaks the api token: %v", err)
	}
}

// TestCloudflareModerator_TimeoutRetried documents that, like
// S3ObjectStore's put/delete, a moderation classification call has no side
// effect, so a timed-out attempt is safe to repeat once.
func TestCloudflareModerator_TimeoutRetried(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if attempts.Add(1) == 1 {
			time.Sleep(300 * time.Millisecond)
			return
		}
		w.Write(cloudflareEnvelope(`{"decision":"allow","categories":[]}`))
	}))
	defer srv.Close()

	m := newTestCloudflareModerator(t, srv.URL, service.WithCloudflareModerationTimeout(50*time.Millisecond))
	if _, err := m.ModerateText(context.Background(), "irrelevant"); err != nil {
		t.Fatalf("expected timed-out attempt to be retried successfully, got %v", err)
	}
	if got := attempts.Load(); got != 2 {
		t.Errorf("expected 2 attempts, got %d", got)
	}
}

func TestCloudflareModerator_CancellationWins(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		time.Sleep(500 * time.Millisecond)
	}))
	defer srv.Close()

	m := newTestCloudflareModerator(t, srv.URL)
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(50*time.Millisecond, cancel)

	_, err := m.ModerateText(ctx, "irrelevant")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}

func TestNewCloudflareModerator_Validation(t *testing.T) {
	if _, err := service.NewCloudflareModerator("", testCloudflareAPIToken, testCloudflareTextModel, testCloudflareVisionModel); err == nil {
		t.Error("expected error for missing account id")
	}
	if _, err := service.NewCloudflareModerator(testCloudflareAccountID, "", testCloudflareTextModel, testCloudflareVisionModel); err == nil {
		t.Error("expected error for missing api token")
	}
	if _, err := service.NewCloudflareModerator(testCloudflareAccountID, testCloudflareAPIToken, "", testCloudflareVisionModel); err == nil {
		t.Error("expected error for missing text model")
	}
	if _, err := service.NewCloudflareModerator(testCloudflareAccountID, testCloudflareAPIToken, testCloudflareTextModel, ""); err == nil {
		t.Error("expected error for missing vision model")
	}
}

func TestCloudflareModerator_ModerateImage_SendsBytesAndPrompt(t *testing.T) {
	var received struct {
		Image  []int  `json:"image"`
		Prompt string `json:"prompt"`
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(raw, &received); err != nil {
			t.Errorf("unmarshal request body: %v", err)
		}
		w.Write(cloudflareEnvelope(`{"decision":"allow","categories":[]}`))
	}))
	defer srv.Close()

	m := newTestCloudflareModerator(t, srv.URL)
	data := []byte{1, 2, 3, 255}
	if _, err := m.ModerateImage(context.Background(), "image/png", data); err != nil {
		t.Fatalf("ModerateImage: %v", err)
	}
	if len(received.Image) != len(data) {
		t.Fatalf("expected %d image bytes, got %d", len(data), len(received.Image))
	}
	for i, b := range data {
		if received.Image[i] != int(b) {
			t.Errorf("byte %d: expected %d, got %d", i, b, received.Image[i])
		}
	}
	if received.Prompt == "" {
		t.Error("expected a non-empty prompt")
	}
}
