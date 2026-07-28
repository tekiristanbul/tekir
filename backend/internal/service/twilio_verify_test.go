package service_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

const (
	testTwilioAccountSID = "test-account-sid"
	testTwilioAuthToken  = "test-auth-token"
	testTwilioServiceSID = "test-verify-service-sid"
	testTwilioPhone      = "+905321112233"
)

// newTestTwilioVerifier wires a TwilioVerifier at a fake twilio server,
// with no retry delay and a short per-attempt timeout so failure tests
// stay fast. It returns the log buffer so tests can assert redaction.
func newTestTwilioVerifier(t *testing.T, handler http.Handler) (*service.TwilioVerifier, *bytes.Buffer) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)

	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))

	tw, err := service.NewTwilioVerifier(testTwilioAccountSID, testTwilioAuthToken, testTwilioServiceSID,
		service.WithTwilioBaseURL(srv.URL),
		service.WithTwilioRetryDelay(0),
		service.WithTwilioTimeout(2*time.Second),
		service.WithTwilioLogger(logger),
	)
	if err != nil {
		t.Fatalf("new twilio verifier: %v", err)
	}
	return tw, &logs
}

func TestNewTwilioVerifier_MissingSettings(t *testing.T) {
	_, err := service.NewTwilioVerifier("", testTwilioAuthToken, "")
	if err == nil {
		t.Fatal("expected error for missing settings")
	}
	for _, name := range []string{"TWILIO_ACCOUNT_SID", "TWILIO_VERIFY_SERVICE_SID"} {
		if !strings.Contains(err.Error(), name) {
			t.Errorf("expected error to mention %s, got %q", name, err)
		}
	}
	if strings.Contains(err.Error(), testTwilioAuthToken) {
		t.Errorf("error leaks a configured value: %q", err)
	}
}

func TestTwilioVerifier_StartVerification_Success(t *testing.T) {
	var gotPath, gotTo, gotChannel string
	var gotUser, gotPass string
	tw, _ := newTestTwilioVerifier(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotUser, gotPass, _ = r.BasicAuth()
		if err := r.ParseForm(); err != nil {
			t.Errorf("parse form: %v", err)
		}
		gotTo = r.PostFormValue("To")
		gotChannel = r.PostFormValue("Channel")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"pending"}`))
	}))

	if err := tw.StartVerification(context.Background(), testTwilioPhone); err != nil {
		t.Fatalf("start verification: %v", err)
	}
	if want := "/v2/Services/" + testTwilioServiceSID + "/Verifications"; gotPath != want {
		t.Errorf("expected path %q, got %q", want, gotPath)
	}
	if gotUser != testTwilioAccountSID || gotPass != testTwilioAuthToken {
		t.Error("expected basic auth with account sid and auth token")
	}
	if gotTo != testTwilioPhone {
		t.Errorf("expected To %q, got %q", testTwilioPhone, gotTo)
	}
	if gotChannel != "sms" {
		t.Errorf("expected Channel sms, got %q", gotChannel)
	}
}

func twilioErrorHandler(status, code int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(`{"code": ` + strconv.Itoa(code) + `, "message": "twilio error"}`))
	})
}

func TestTwilioVerifier_StartVerification_ErrorMapping(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		code    int
		wantErr error
	}{
		{name: "invalid phone", status: http.StatusBadRequest, code: 60200, wantErr: service.ErrInvalidPhone},
		{name: "max send attempts", status: http.StatusBadRequest, code: 60203, wantErr: service.ErrOTPResendTooSoon},
		{name: "concurrent limit", status: http.StatusBadRequest, code: 60212, wantErr: service.ErrOTPResendTooSoon},
		{name: "rate limited", status: http.StatusTooManyRequests, code: 20429, wantErr: service.ErrOTPResendTooSoon},
		{name: "authentication failure", status: http.StatusUnauthorized, code: 20003, wantErr: service.ErrOTPProviderUnavailable},
		{name: "service not found", status: http.StatusNotFound, code: 20404, wantErr: service.ErrOTPProviderUnavailable},
		{name: "unclassified client error", status: http.StatusBadRequest, code: 12345, wantErr: service.ErrOTPProviderUnavailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tw, _ := newTestTwilioVerifier(t, twilioErrorHandler(tc.status, tc.code))
			if err := tw.StartVerification(context.Background(), testTwilioPhone); !errors.Is(err, tc.wantErr) {
				t.Errorf("expected %v, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestTwilioVerifier_CheckVerification_Success(t *testing.T) {
	var gotPath, gotTo, gotCode string
	tw, _ := newTestTwilioVerifier(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		if err := r.ParseForm(); err != nil {
			t.Errorf("parse form: %v", err)
		}
		gotTo = r.PostFormValue("To")
		gotCode = r.PostFormValue("Code")
		_, _ = w.Write([]byte(`{"status":"approved"}`))
	}))

	if err := tw.CheckVerification(context.Background(), testTwilioPhone, "123456"); err != nil {
		t.Fatalf("check verification: %v", err)
	}
	if want := "/v2/Services/" + testTwilioServiceSID + "/VerificationCheck"; gotPath != want {
		t.Errorf("expected path %q, got %q", want, gotPath)
	}
	if gotTo != testTwilioPhone || gotCode != "123456" {
		t.Errorf("expected To/Code to be submitted, got %q/%q", gotTo, gotCode)
	}
}

func TestTwilioVerifier_CheckVerification_Outcomes(t *testing.T) {
	cases := []struct {
		name    string
		handler http.Handler
		wantErr error
	}{
		{name: "wrong code stays pending", handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"status":"pending"}`))
		}), wantErr: service.ErrOTPCodeMismatch},
		{name: "canceled verification", handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"status":"canceled"}`))
		}), wantErr: service.ErrOTPExpired},
		{name: "expired or consumed answers 404", handler: twilioErrorHandler(http.StatusNotFound, 20404), wantErr: service.ErrOTPExpired},
		{name: "max check attempts", handler: twilioErrorHandler(http.StatusBadRequest, 60202), wantErr: service.ErrOTPTooManyAttempts},
		{name: "rate limited", handler: twilioErrorHandler(http.StatusTooManyRequests, 20429), wantErr: service.ErrOTPTooManyAttempts},
		{name: "invalid phone", handler: twilioErrorHandler(http.StatusBadRequest, 60200), wantErr: service.ErrInvalidPhone},
		{name: "authentication failure", handler: twilioErrorHandler(http.StatusUnauthorized, 20003), wantErr: service.ErrOTPProviderUnavailable},
		{name: "malformed success body", handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`not json`))
		}), wantErr: service.ErrOTPProviderUnavailable},
		{name: "unknown success status", handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"status":"mystery"}`))
		}), wantErr: service.ErrOTPProviderUnavailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tw, _ := newTestTwilioVerifier(t, tc.handler)
			if err := tw.CheckVerification(context.Background(), testTwilioPhone, "123456"); !errors.Is(err, tc.wantErr) {
				t.Errorf("expected %v, got %v", tc.wantErr, err)
			}
		})
	}
}

// TestTwilioVerifier_RetriesServerErrorOnce proves the transient-failure
// retry is bounded to exactly one extra attempt and recovers when the
// second attempt succeeds.
func TestTwilioVerifier_RetriesServerErrorOnce(t *testing.T) {
	var calls atomic.Int32
	tw, _ := newTestTwilioVerifier(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"pending"}`))
	}))

	if err := tw.StartVerification(context.Background(), testTwilioPhone); err != nil {
		t.Fatalf("expected retried start to succeed, got %v", err)
	}
	if got := calls.Load(); got != 2 {
		t.Errorf("expected exactly 2 attempts, got %d", got)
	}
}

func TestTwilioVerifier_PersistentServerErrorIsUnavailable(t *testing.T) {
	var calls atomic.Int32
	tw, _ := newTestTwilioVerifier(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))

	if err := tw.StartVerification(context.Background(), testTwilioPhone); !errors.Is(err, service.ErrOTPProviderUnavailable) {
		t.Fatalf("expected ErrOTPProviderUnavailable, got %v", err)
	}
	if got := calls.Load(); got != 2 {
		t.Errorf("expected retry to be bounded at 2 attempts, got %d", got)
	}
}

// TestTwilioVerifier_TimeoutIsNotRetried proves a per-attempt timeout maps
// to provider-unavailable without a second attempt — a timed-out start may
// already have sent an sms, so repeating it is not safe.
func TestTwilioVerifier_TimeoutIsNotRetried(t *testing.T) {
	var calls atomic.Int32
	// blocks until the client gives up — waiting on the request context
	// (not a test-owned channel) so srv.Close never deadlocks on a still
	// blocked handler. The body must be drained first: the server only
	// detects a client disconnect (and cancels the context) once no unread
	// request body remains.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		_, _ = io.Copy(io.Discard, r.Body)
		<-r.Context().Done()
	}))
	t.Cleanup(srv.Close)

	tw, err := service.NewTwilioVerifier(testTwilioAccountSID, testTwilioAuthToken, testTwilioServiceSID,
		service.WithTwilioBaseURL(srv.URL),
		service.WithTwilioRetryDelay(0),
		service.WithTwilioTimeout(50*time.Millisecond),
		service.WithTwilioLogger(slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil))),
	)
	if err != nil {
		t.Fatalf("new twilio verifier: %v", err)
	}

	if err := tw.StartVerification(context.Background(), testTwilioPhone); !errors.Is(err, service.ErrOTPProviderUnavailable) {
		t.Fatalf("expected ErrOTPProviderUnavailable on timeout, got %v", err)
	}
	if got := calls.Load(); got != 1 {
		t.Errorf("expected a timed-out attempt not to be retried, got %d attempts", got)
	}
}

// TestTwilioVerifier_CancelledRequestStops proves cancelling the incoming
// request cancels the outbound call: the caller gets the context error, not
// a mapped provider error, and nothing retries.
func TestTwilioVerifier_CancelledRequestStops(t *testing.T) {
	started := make(chan struct{})
	// blocks until the client cancels — waiting on the request context
	// (body drained first, see TestTwilioVerifier_TimeoutIsNotRetried) so
	// srv.Close never deadlocks on a still-blocked handler.
	tw, _ := newTestTwilioVerifier(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		close(started)
		<-r.Context().Done()
	}))

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-started
		cancel()
	}()

	err := tw.CheckVerification(ctx, testTwilioPhone, "123456")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}

func TestTwilioVerifier_DialErrorIsUnavailable(t *testing.T) {
	// a server that is already closed — every dial is refused.
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	srv.Close()

	tw, err := service.NewTwilioVerifier(testTwilioAccountSID, testTwilioAuthToken, testTwilioServiceSID,
		service.WithTwilioBaseURL(srv.URL),
		service.WithTwilioRetryDelay(0),
		service.WithTwilioLogger(slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil))),
	)
	if err != nil {
		t.Fatalf("new twilio verifier: %v", err)
	}
	if err := tw.StartVerification(context.Background(), testTwilioPhone); !errors.Is(err, service.ErrOTPProviderUnavailable) {
		t.Fatalf("expected ErrOTPProviderUnavailable, got %v", err)
	}
}

// TestTwilioVerifier_LogsAreRedacted proves failure logging never includes
// the phone number, the submitted code, credentials, the verify service
// sid, or the raw response body.
func TestTwilioVerifier_LogsAreRedacted(t *testing.T) {
	secretBody := `{"code": 60203, "message": "Max send attempts reached for ` + testTwilioPhone + `"}`
	tw, logs := newTestTwilioVerifier(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(secretBody))
	}))

	if err := tw.CheckVerification(context.Background(), testTwilioPhone, "987654"); !errors.Is(err, service.ErrOTPProviderUnavailable) {
		t.Fatalf("expected ErrOTPProviderUnavailable, got %v", err)
	}

	out := logs.String()
	if out == "" {
		t.Fatal("expected the failure to be logged")
	}
	for _, secret := range []string{testTwilioPhone, "987654", testTwilioAuthToken, testTwilioAccountSID, testTwilioServiceSID, "Max send attempts"} {
		if strings.Contains(out, secret) {
			t.Errorf("log output leaks %q:\n%s", secret, out)
		}
	}
}
