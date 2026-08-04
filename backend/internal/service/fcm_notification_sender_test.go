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
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/oauth2"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

const (
	testFCMProjectID   = "tekir-test-project"
	testFCMAccessToken = "test-access-token-value"
	testFCMPushToken   = "test-fcm-registration-token-value"
)

// writeTestServiceAccount writes a syntactically valid service-account json
// to a temp file. The private key is a placeholder — every test overrides
// the token source, so the key is never parsed or used to sign anything.
func writeTestServiceAccount(t *testing.T, projectID string) string {
	t.Helper()
	doc := map[string]string{
		"type":         "service_account",
		"project_id":   projectID,
		"private_key":  "-----BEGIN PRIVATE KEY-----\nplaceholder\n-----END PRIVATE KEY-----\n",
		"client_email": "notifier@" + projectID + ".iam.gserviceaccount.com",
		"token_uri":    "https://example.invalid/token",
	}
	data, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal service account: %v", err)
	}
	path := filepath.Join(t.TempDir(), "service-account.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write service account: %v", err)
	}
	return path
}

// newTestFCMSender wires an FCMNotificationSender at a fake fcm server with
// a static token source, no retry delay, and a short per-attempt timeout.
// It returns the log buffer so tests can assert redaction.
func newTestFCMSender(t *testing.T, handler http.Handler) (*service.FCMNotificationSender, *bytes.Buffer) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)

	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))

	sender, err := service.NewFCMNotificationSender(writeTestServiceAccount(t, testFCMProjectID),
		service.WithFCMBaseURL(srv.URL),
		service.WithFCMRetryDelay(0),
		service.WithFCMTimeout(2*time.Second),
		service.WithFCMLogger(logger),
		service.WithFCMTokenSource(oauth2.StaticTokenSource(&oauth2.Token{AccessToken: testFCMAccessToken})),
	)
	if err != nil {
		t.Fatalf("new fcm sender: %v", err)
	}
	return sender, &logs
}

func testPushMessage() service.PushMessage {
	return service.PushMessage{
		DeviceID:  "device-id-1",
		PushToken: testFCMPushToken,
		CatID:     "cat-id-1",
		UpdateID:  "update-id-1",
	}
}

// fcmErrorBody builds a v1 error response body with the given google.rpc
// status and fcm errorCode detail.
func fcmErrorBody(rpcStatus, errorCode string) string {
	return `{"error":{"code":0,"message":"redacted","status":"` + rpcStatus + `","details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"` + errorCode + `"}]}}`
}

func TestNewFCMNotificationSender_Validation(t *testing.T) {
	if _, err := service.NewFCMNotificationSender(""); err == nil {
		t.Fatal("expected error for empty credentials file setting")
	} else if !strings.Contains(err.Error(), "FCM_CREDENTIALS_FILE") {
		t.Errorf("expected error to mention FCM_CREDENTIALS_FILE, got %q", err)
	}

	if _, err := service.NewFCMNotificationSender(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Fatal("expected error for nonexistent credentials file")
	}

	badPath := filepath.Join(t.TempDir(), "bad.json")
	if err := os.WriteFile(badPath, []byte("not json"), 0o600); err != nil {
		t.Fatalf("write bad json: %v", err)
	}
	if _, err := service.NewFCMNotificationSender(badPath); err == nil {
		t.Fatal("expected error for invalid credentials json")
	} else if strings.Contains(err.Error(), "not json") {
		t.Errorf("error echoes credentials file contents: %q", err)
	}

	if _, err := service.NewFCMNotificationSender(writeTestServiceAccount(t, "")); err == nil {
		t.Fatal("expected error for credentials json without project_id")
	}
}

func TestFCMSender_Send_Success(t *testing.T) {
	var gotPath, gotAuth, gotContentType string
	var gotBody map[string]any
	sender, _ := newTestFCMSender(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		gotContentType = r.Header.Get("Content-Type")
		if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
			t.Errorf("decode body: %v", err)
		}
		_, _ = w.Write([]byte(`{"name":"projects/` + testFCMProjectID + `/messages/1"}`))
	}))

	if err := sender.Send(context.Background(), testPushMessage()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if want := "/v1/projects/" + testFCMProjectID + "/messages:send"; gotPath != want {
		t.Errorf("expected path %q, got %q", want, gotPath)
	}
	if gotAuth != "Bearer "+testFCMAccessToken {
		t.Errorf("expected oauth2 bearer auth, got %q", gotAuth)
	}
	if gotContentType != "application/json" {
		t.Errorf("expected json content type, got %q", gotContentType)
	}

	message, _ := gotBody["message"].(map[string]any)
	if message == nil {
		t.Fatalf("expected a message object, got %v", gotBody)
	}
	if message["token"] != testFCMPushToken {
		t.Errorf("expected message.token to carry the push token, got %v", message["token"])
	}
	data, _ := message["data"].(map[string]any)
	if data == nil {
		t.Fatalf("expected message.data, got %v", message)
	}
	for key, want := range map[string]string{"type": "needs_help", "cat_id": "cat-id-1", "update_id": "update-id-1"} {
		if data[key] != want {
			t.Errorf("expected data.%s = %q, got %v", key, want, data[key])
		}
	}
	// issue #101: the category key is retired with the #100 contract's
	// category vocabulary — it must never reappear in a push payload.
	if _, ok := data["category"]; ok {
		t.Errorf("expected no data.category key, got %v", data["category"])
	}
	if notification, _ := message["notification"].(map[string]any); notification == nil || notification["title"] == "" {
		t.Errorf("expected a notification payload for terminated-app display, got %v", message["notification"])
	}
}

func TestFCMSender_Send_TokenOutcomes(t *testing.T) {
	cases := []struct {
		name        string
		status      int
		body        string
		wantInvalid bool
	}{
		{name: "unregistered token", status: http.StatusNotFound, body: fcmErrorBody("NOT_FOUND", "UNREGISTERED"), wantInvalid: true},
		{name: "plain 404 without detail", status: http.StatusNotFound, body: `{}`, wantInvalid: true},
		{name: "invalid argument token", status: http.StatusBadRequest, body: fcmErrorBody("INVALID_ARGUMENT", "INVALID_ARGUMENT"), wantInvalid: true},
		{name: "sender id mismatch", status: http.StatusForbidden, body: fcmErrorBody("PERMISSION_DENIED", "SENDER_ID_MISMATCH"), wantInvalid: true},
		{name: "quota exceeded is transient", status: http.StatusTooManyRequests, body: fcmErrorBody("RESOURCE_EXHAUSTED", "QUOTA_EXCEEDED"), wantInvalid: false},
		{name: "auth failure is transient", status: http.StatusUnauthorized, body: fcmErrorBody("UNAUTHENTICATED", ""), wantInvalid: false},
		{name: "malformed error body", status: http.StatusConflict, body: "not json", wantInvalid: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sender, logs := newTestFCMSender(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))

			err := sender.Send(context.Background(), testPushMessage())
			if err == nil {
				t.Fatal("expected an error")
			}
			if got := errors.Is(err, service.ErrPushTokenInvalid); got != tc.wantInvalid {
				t.Errorf("ErrPushTokenInvalid = %v, want %v (err %q)", got, tc.wantInvalid, err)
			}
			if strings.Contains(err.Error(), testFCMPushToken) {
				t.Errorf("error leaks the push token: %q", err)
			}
			if strings.Contains(logs.String(), testFCMPushToken) || strings.Contains(logs.String(), testFCMAccessToken) {
				t.Errorf("logs leak a token: %s", logs.String())
			}
		})
	}
}

func TestFCMSender_RetriesServerErrorOnce(t *testing.T) {
	var calls int
	sender, _ := newTestFCMSender(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		if calls == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`{"name":"projects/x/messages/1"}`))
	}))

	if err := sender.Send(context.Background(), testPushMessage()); err != nil {
		t.Fatalf("expected retry to succeed, got %v", err)
	}
	if calls != 2 {
		t.Errorf("expected exactly 2 attempts, got %d", calls)
	}
}

func TestFCMSender_PersistentServerErrorFails(t *testing.T) {
	var calls int
	sender, _ := newTestFCMSender(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		w.WriteHeader(http.StatusInternalServerError)
	}))

	err := sender.Send(context.Background(), testPushMessage())
	if err == nil {
		t.Fatal("expected an error after persistent 5xx")
	}
	if errors.Is(err, service.ErrPushTokenInvalid) {
		t.Errorf("a 5xx must never be classified as an invalid token: %v", err)
	}
	if calls != 2 {
		t.Errorf("expected exactly 2 attempts, got %d", calls)
	}
}

func TestFCMSender_TimeoutIsNotRetried(t *testing.T) {
	var calls int
	// blocks until the client gives up — waiting on the request context
	// (not a test-owned channel) so srv.Close never deadlocks on a still
	// blocked handler. The body must be drained first: the server only
	// detects a client disconnect (and cancels the context) once no unread
	// request body remains (mirrors TestTwilioVerifier_TimeoutIsNotRetried).
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		calls++
		_, _ = io.Copy(io.Discard, r.Body)
		<-r.Context().Done()
	}))
	t.Cleanup(srv.Close)

	var logs bytes.Buffer
	sender, err := service.NewFCMNotificationSender(writeTestServiceAccount(t, testFCMProjectID),
		service.WithFCMBaseURL(srv.URL),
		service.WithFCMRetryDelay(0),
		service.WithFCMTimeout(50*time.Millisecond),
		service.WithFCMLogger(slog.New(slog.NewTextHandler(&logs, nil))),
		service.WithFCMTokenSource(oauth2.StaticTokenSource(&oauth2.Token{AccessToken: testFCMAccessToken})),
	)
	if err != nil {
		t.Fatalf("new fcm sender: %v", err)
	}

	if err := sender.Send(context.Background(), testPushMessage()); err == nil {
		t.Fatal("expected timeout error")
	}
	if calls != 1 {
		t.Errorf("a timed-out attempt must not be retried, got %d attempts", calls)
	}
}

func TestFCMSender_CancelledContextStops(t *testing.T) {
	sender, _ := newTestFCMSender(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := sender.Send(ctx, testPushMessage()); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}

// failingTokenSource simulates an oauth2 exchange failure whose error text
// embeds sensitive material — the sender must classify it, never propagate
// or log it verbatim.
type failingTokenSource struct{}

func (failingTokenSource) Token() (*oauth2.Token, error) {
	return nil, errors.New("oauth2: secret-material-in-error")
}

func TestFCMSender_TokenFetchFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		t.Error("fcm endpoint must not be called when the token fetch fails")
	}))
	t.Cleanup(srv.Close)

	var logs bytes.Buffer
	sender, err := service.NewFCMNotificationSender(writeTestServiceAccount(t, testFCMProjectID),
		service.WithFCMBaseURL(srv.URL),
		service.WithFCMRetryDelay(0),
		service.WithFCMLogger(slog.New(slog.NewTextHandler(&logs, nil))),
		service.WithFCMTokenSource(failingTokenSource{}),
	)
	if err != nil {
		t.Fatalf("new fcm sender: %v", err)
	}

	sendErr := sender.Send(context.Background(), testPushMessage())
	if sendErr == nil {
		t.Fatal("expected an error when the token fetch fails")
	}
	if errors.Is(sendErr, service.ErrPushTokenInvalid) {
		t.Errorf("an auth failure must never retire the push token: %v", sendErr)
	}
	if strings.Contains(sendErr.Error(), "secret-material-in-error") {
		t.Errorf("error propagates oauth2 failure verbatim: %q", sendErr)
	}
	if strings.Contains(logs.String(), "secret-material-in-error") {
		t.Errorf("logs echo the oauth2 failure verbatim: %s", logs.String())
	}
}

func TestFCMSender_EmptyPushTokenRejected(t *testing.T) {
	sender, _ := newTestFCMSender(t, http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		t.Error("fcm endpoint must not be called for an empty push token")
	}))

	msg := testPushMessage()
	msg.PushToken = ""
	if err := sender.Send(context.Background(), msg); err == nil {
		t.Fatal("expected an error for an empty push token")
	}
}
