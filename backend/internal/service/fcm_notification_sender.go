package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

const (
	fcmDefaultBaseURL = "https://fcm.googleapis.com"
	// fcmScope is the oauth2 scope fcm http v1 requires. v1 with
	// service-account credentials is the only supported auth path — legacy
	// server keys are deliberately not implemented (issue #84).
	fcmScope = "https://www.googleapis.com/auth/firebase.messaging"
	// fcmDefaultTimeout bounds one outbound attempt. Derived from the
	// caller's context, so worker shutdown cancels the outbound call too.
	fcmDefaultTimeout = 10 * time.Second
	// fcmRetryDelay separates the single retry from the failed attempt.
	fcmRetryDelay = 250 * time.Millisecond
	// fcmMaxResponseBytes caps how much of a response body is ever read.
	fcmMaxResponseBytes = 1 << 20
)

// fcm v1 errorCode values this adapter classifies — the documented public
// FcmError catalog (https://firebase.google.com/docs/reference/fcm/rest/v1/ErrorCode).
const (
	fcmCodeUnregistered     = "UNREGISTERED"
	fcmCodeInvalidArgument  = "INVALID_ARGUMENT"
	fcmCodeSenderIDMismatch = "SENDER_ID_MISMATCH"
	fcmCodeQuotaExceeded    = "QUOTA_EXCEEDED"
)

// Push notification copy lives server-side because a background or
// terminated app can only display what the fcm notification payload itself
// carries — there is no client code running to compose it. Deliberately
// generic (docs/product/notifications.md, docs/product/privacy.md): no cat
// name, no location, no free text; the specifics live behind the tap, in
// the app's own notification/cat-detail surface.
const (
	fcmNotificationTitle = "Yardım çağrısı"
	fcmNotificationBody  = "Takip ettiğin bir kedinin yardıma ihtiyacı var."
)

// FCMNotificationSender is the firebase cloud messaging implementation of
// NotificationSender (issue #84), talking to the fcm http v1 send endpoint
// directly — the same hand-rolled adapter shape as TwilioVerifier (issue
// #59) rather than the admin sdk, keeping the dependency surface at
// x/oauth2 only.
//
// Failure handling is fail-closed and bounded: one retry, and only for
// failures known to be safe to repeat (a 5xx response, or a dial error
// where the request never reached fcm). A per-attempt timeout is never
// retried in-place — the outbox's existing claim/dedupe semantics own
// redelivery (see NotificationService.DispatchPending). A permanently
// rejected token is reported as ErrPushTokenInvalid so the caller can
// retire it. Nothing sensitive is ever logged: no registration tokens,
// credentials, or raw response bodies — only coarse outcome fields.
type FCMNotificationSender struct {
	client      *http.Client
	logger      *slog.Logger
	baseURL     string
	projectID   string
	tokenSource oauth2.TokenSource
	timeout     time.Duration
	retryDelay  time.Duration
}

// FCMOption configures optional FCMNotificationSender behavior.
type FCMOption func(*FCMNotificationSender)

// WithFCMBaseURL points the adapter at a different endpoint — tests use
// this to stand up a local fake fcm server.
func WithFCMBaseURL(u string) FCMOption {
	return func(f *FCMNotificationSender) { f.baseURL = strings.TrimRight(u, "/") }
}

// WithFCMTimeout overrides the per-attempt request timeout.
func WithFCMTimeout(d time.Duration) FCMOption {
	return func(f *FCMNotificationSender) { f.timeout = d }
}

// WithFCMRetryDelay overrides the delay before the single retry — tests
// set it to zero.
func WithFCMRetryDelay(d time.Duration) FCMOption {
	return func(f *FCMNotificationSender) { f.retryDelay = d }
}

// WithFCMLogger overrides the logger — tests use it to assert redaction.
func WithFCMLogger(l *slog.Logger) FCMOption {
	return func(f *FCMNotificationSender) { f.logger = l }
}

// WithFCMTokenSource replaces the service-account token source — tests use
// it to avoid a real oauth2 exchange, or to simulate an auth failure.
func WithFCMTokenSource(ts oauth2.TokenSource) FCMOption {
	return func(f *FCMNotificationSender) { f.tokenSource = ts }
}

// NewFCMNotificationSender reads and validates the service-account
// credentials at startup — selecting fcm with unreadable or incomplete
// credentials must fail the process, not degrade at runtime (issue #84's
// no-silent-fallback constraint). The firebase project id is taken from
// the credentials json's project_id; error messages never echo the file's
// contents.
func NewFCMNotificationSender(credentialsFile string, opts ...FCMOption) (*FCMNotificationSender, error) {
	f := &FCMNotificationSender{
		client:     &http.Client{},
		logger:     slog.Default(),
		baseURL:    fcmDefaultBaseURL,
		timeout:    fcmDefaultTimeout,
		retryDelay: fcmRetryDelay,
	}
	for _, opt := range opts {
		opt(f)
	}

	if credentialsFile == "" {
		return nil, errors.New("fcm: missing required setting: FCM_CREDENTIALS_FILE")
	}
	data, err := os.ReadFile(credentialsFile)
	if err != nil {
		return nil, fmt.Errorf("fcm: reading FCM_CREDENTIALS_FILE: %w", err)
	}
	// JWTConfigFromJSON (not the deprecated CredentialsFromJSON): the file
	// is an operator-supplied deployment secret, and the service-account
	// jwt flow is exactly what fcm v1 requires. project_id isn't part of
	// jwt.Config, so it's read from the same json separately.
	var meta struct {
		ProjectID string `json:"project_id"`
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		// the underlying error can quote fields of the credentials json —
		// never propagate it verbatim.
		return nil, errors.New("fcm: FCM_CREDENTIALS_FILE is not a valid service-account json")
	}
	if meta.ProjectID == "" {
		return nil, errors.New("fcm: credentials json has no project_id")
	}
	f.projectID = meta.ProjectID
	if f.tokenSource == nil {
		jwtConfig, err := google.JWTConfigFromJSON(data, fcmScope)
		if err != nil {
			return nil, errors.New("fcm: FCM_CREDENTIALS_FILE is not a valid service-account json")
		}
		// context.Background deliberately: the token source outlives any
		// single send and caches/refreshes tokens across calls; per-send
		// deadlines still bound the message request itself. The
		// oauth2.HTTPClient value bounds the token exchange — Token() takes
		// no context, and an unbounded default client could otherwise hang
		// the whole worker on a stuck token fetch.
		tokenCtx := context.WithValue(context.Background(), oauth2.HTTPClient, &http.Client{Timeout: f.timeout})
		f.tokenSource = jwtConfig.TokenSource(tokenCtx)
	}
	return f, nil
}

// fcmMessage is the http v1 request body for one send.
type fcmMessage struct {
	Message struct {
		Token        string            `json:"token"`
		Notification map[string]string `json:"notification"`
		Data         map[string]string `json:"data"`
		Android      struct {
			Priority string `json:"priority"`
		} `json:"android"`
	} `json:"message"`
}

// Send delivers one needs-help push through the fcm v1 send endpoint.
func (f *FCMNotificationSender) Send(ctx context.Context, msg PushMessage) error {
	if msg.PushToken == "" {
		// DispatchPending never sends for a token-less device; reaching
		// this is a programming error, not a provider outcome.
		return errors.New("fcm: empty push token")
	}

	var body fcmMessage
	body.Message.Token = msg.PushToken
	body.Message.Notification = map[string]string{
		"title": fcmNotificationTitle,
		"body":  fcmNotificationBody,
	}
	// data mirrors what the in-app notification record carries, so the tap
	// handler can deep-link to the same cat detail the notifications screen
	// would (issue #84). Only the recipient's own device ever sees this.
	// The category key was dropped by issue #101 (the #100 contract retires
	// the category vocabulary; the 0.1 push handler never read it) — the
	// note is deliberately not included either: the payload stays minimal
	// and free of user-generated content.
	body.Message.Data = map[string]string{
		"type":      "needs_help",
		"cat_id":    msg.CatID,
		"update_id": msg.UpdateID,
	}
	// high priority: a needs-help alert is the one push this product sends
	// (docs/product/notifications.md) and it is time-sensitive by nature.
	body.Message.Android.Priority = "high"

	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}

	status, respBody, err := f.post(ctx, payload)
	if err != nil {
		return err
	}
	if status/100 == 2 {
		// the v1 response body (a message name) is deliberately unused —
		// provider message ids are never stored or exposed (issue #84).
		return nil
	}

	rpcStatus, fcmCode := fcmError(respBody)
	switch {
	case fcmCode == fcmCodeUnregistered || status == http.StatusNotFound:
		// this installation's token is gone (app uninstalled, token
		// rotated away). Permanent for this token — retire it.
		return ErrPushTokenInvalid
	case fcmCode == fcmCodeSenderIDMismatch:
		// the token was minted for a different firebase project; it can
		// never work for ours. Permanent — retire it.
		return ErrPushTokenInvalid
	case fcmCode == fcmCodeInvalidArgument || status == http.StatusBadRequest:
		// fcm reports a malformed registration token as INVALID_ARGUMENT.
		// The payload shape here is fixed and covered by tests, so a 400 on
		// a live send means the token, not the message — retire it rather
		// than retrying it forever.
		return ErrPushTokenInvalid
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		f.logger.Error("fcm rejected the configured credentials", "http_status", status, "rpc_status", rpcStatus, "fcm_code", fcmCode)
		return fmt.Errorf("fcm: authentication failed (http %d)", status)
	case status == http.StatusTooManyRequests || fcmCode == fcmCodeQuotaExceeded:
		f.logger.Warn("fcm send rate-limited", "http_status", status, "fcm_code", fcmCode)
		return fmt.Errorf("fcm: rate limited (http %d)", status)
	default:
		f.logger.Warn("fcm send failed", "http_status", status, "rpc_status", rpcStatus, "fcm_code", fcmCode)
		return fmt.Errorf("fcm: send failed (http %d)", status)
	}
}

// post runs one v1 send request with at most one retry — the same bounded
// policy as TwilioVerifier.post (issue #59): retry only when repeating is
// known to be safe (a 5xx response, or a dial error where the request never
// reached fcm). A per-attempt timeout or any other mid-flight failure is
// not retried — fcm may already have accepted the message, and a repeat
// would deliver it twice. Cancellation of the incoming ctx always wins.
//
// Transport errors are never logged verbatim — only errorKind's coarse
// classification, so no url, token, or credential material can leak.
func (f *FCMNotificationSender) post(ctx context.Context, payload []byte) (int, []byte, error) {
	const maxAttempts = 2
	for attempt := 1; ; attempt++ {
		status, body, err := f.postOnce(ctx, payload)
		if err == nil && status < 500 {
			return status, body, nil
		}
		if ctx.Err() != nil {
			return 0, nil, ctx.Err()
		}
		if err != nil && !isDialError(err) {
			f.logger.Warn("fcm request failed", "attempt", attempt, "error_kind", errorKind(err))
			return 0, nil, fmt.Errorf("fcm: request failed (%s)", errorKind(err))
		}
		if attempt >= maxAttempts {
			f.logger.Warn("fcm unavailable after retry", "http_status", status, "error_kind", errorKind(err))
			return 0, nil, errors.New("fcm: unavailable after retry")
		}
		if f.retryDelay > 0 {
			timer := time.NewTimer(f.retryDelay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return 0, nil, ctx.Err()
			case <-timer.C:
			}
		}
	}
}

func (f *FCMNotificationSender) postOnce(ctx context.Context, payload []byte) (int, []byte, error) {
	reqCtx, cancel := context.WithTimeout(ctx, f.timeout)
	defer cancel()

	token, err := f.tokenSource.Token()
	if err != nil {
		// the oauth2 error can embed request/response detail — classify,
		// never propagate verbatim.
		f.logger.Error("fcm access token fetch failed", "error_kind", errorKind(err))
		return 0, nil, errors.New("fcm: could not obtain access token")
	}

	url := f.baseURL + "/v1/projects/" + f.projectID + "/messages:send"
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token.AccessToken)

	resp, err := f.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, fcmMaxResponseBytes))
	if err != nil {
		return 0, nil, err
	}
	return resp.StatusCode, body, nil
}

// fcmError extracts the google.rpc status string and the fcm-specific
// errorCode from a v1 error body, or empty strings when there is nothing
// to extract.
func fcmError(body []byte) (rpcStatus, fcmCode string) {
	var res struct {
		Error struct {
			Status  string `json:"status"`
			Details []struct {
				Type      string `json:"@type"`
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &res); err != nil {
		return "", ""
	}
	for _, d := range res.Error.Details {
		if d.ErrorCode != "" {
			return res.Error.Status, d.ErrorCode
		}
	}
	return res.Error.Status, ""
}
