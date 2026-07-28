package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// twilio verify error codes this adapter classifies — the documented
// public catalog values, not secrets (https://www.twilio.com/docs/api/errors).
const (
	twilioCodeInvalidParameter = 60200 // malformed To/parameter → invalid phone
	twilioCodeMaxCheckAttempts = 60202 // per-verification guess limit reached
	twilioCodeMaxSendAttempts  = 60203 // per-verification send limit reached
	twilioCodeConcurrentLimit  = 60212 // too many concurrent requests for one number
)

const (
	twilioDefaultBaseURL = "https://verify.twilio.com"
	// twilioDefaultTimeout bounds one outbound attempt. Derived from the
	// incoming request's context, so a cancelled client request cancels
	// the outbound call too.
	twilioDefaultTimeout = 10 * time.Second
	// twilioRetryDelay separates the single retry from the failed attempt.
	twilioRetryDelay = 250 * time.Millisecond
	// twilioMaxResponseBytes caps how much of a response body is ever read.
	twilioMaxResponseBytes = 1 << 20
)

// TwilioVerifier is the twilio verify implementation of
// OTPVerificationProvider (issue #59): StartVerification creates a
// verification through the configured verify service over the sms channel,
// CheckVerification submits the user's code to the verification-check
// endpoint. Only TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, and
// TWILIO_VERIFY_SERVICE_SID are required — verify has no sender number, so
// TWILIO_NUMBER is deliberately not part of this adapter's contract.
//
// Failure handling is fail-closed and bounded: one retry, and only for
// failures known to be safe to repeat (a 5xx response, or a dial error
// where the request never reached twilio). A per-attempt timeout is never
// retried — a timed-out StartVerification may already have sent an sms.
// Nothing sensitive is ever logged: no phone numbers, codes, sids, tokens,
// or raw response bodies — only coarse outcome fields.
type TwilioVerifier struct {
	client     *http.Client
	logger     *slog.Logger
	baseURL    string
	accountSID string
	authToken  string
	serviceSID string
	timeout    time.Duration
	retryDelay time.Duration
}

// TwilioVerifierOption configures optional TwilioVerifier behavior.
type TwilioVerifierOption func(*TwilioVerifier)

// WithTwilioBaseURL points the adapter at a different endpoint — tests use
// this to stand up a local fake twilio server.
func WithTwilioBaseURL(u string) TwilioVerifierOption {
	return func(t *TwilioVerifier) { t.baseURL = strings.TrimRight(u, "/") }
}

// WithTwilioTimeout overrides the per-attempt request timeout.
func WithTwilioTimeout(d time.Duration) TwilioVerifierOption {
	return func(t *TwilioVerifier) { t.timeout = d }
}

// WithTwilioRetryDelay overrides the delay before the single retry — tests
// set it to zero.
func WithTwilioRetryDelay(d time.Duration) TwilioVerifierOption {
	return func(t *TwilioVerifier) { t.retryDelay = d }
}

// WithTwilioLogger overrides the logger — tests use it to assert redaction.
func WithTwilioLogger(l *slog.Logger) TwilioVerifierOption {
	return func(t *TwilioVerifier) { t.logger = l }
}

// NewTwilioVerifier validates that every required setting is present —
// selecting twilio with an incomplete configuration must fail startup, not
// degrade at runtime (issue #59). The error names the missing variables
// but never echoes any configured value.
func NewTwilioVerifier(accountSID, authToken, verifyServiceSID string, opts ...TwilioVerifierOption) (*TwilioVerifier, error) {
	var missing []string
	if accountSID == "" {
		missing = append(missing, "TWILIO_ACCOUNT_SID")
	}
	if authToken == "" {
		missing = append(missing, "TWILIO_AUTH_TOKEN")
	}
	if verifyServiceSID == "" {
		missing = append(missing, "TWILIO_VERIFY_SERVICE_SID")
	}
	if len(missing) > 0 {
		return nil, errors.New("twilio verify: missing required settings: " + strings.Join(missing, ", "))
	}

	t := &TwilioVerifier{
		client:     &http.Client{},
		logger:     slog.Default(),
		baseURL:    twilioDefaultBaseURL,
		accountSID: accountSID,
		authToken:  authToken,
		serviceSID: verifyServiceSID,
		timeout:    twilioDefaultTimeout,
		retryDelay: twilioRetryDelay,
	}
	for _, opt := range opts {
		opt(t)
	}
	return t, nil
}

// StartVerification asks the verify service to generate and deliver a code
// to phone over sms.
func (t *TwilioVerifier) StartVerification(ctx context.Context, phone string) error {
	status, body, err := t.post(ctx, "start", "/v2/Services/"+t.serviceSID+"/Verifications", url.Values{
		"To":      {phone},
		"Channel": {"sms"},
	})
	if err != nil {
		return err
	}
	if status/100 == 2 {
		// 201 with status "pending" — the code is on its way. The body is
		// deliberately not validated further: a 2xx means the verification
		// was created, and failing here would reject a send that happened.
		return nil
	}

	code := twilioErrorCode(body)
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		t.logger.Error("twilio verify rejected the configured credentials", "op", "start", "http_status", status, "twilio_code", code)
		return ErrOTPProviderUnavailable
	case status == http.StatusNotFound:
		t.logger.Error("twilio verify service not found — check TWILIO_VERIFY_SERVICE_SID", "op", "start", "http_status", status, "twilio_code", code)
		return ErrOTPProviderUnavailable
	case status == http.StatusTooManyRequests || code == twilioCodeMaxSendAttempts || code == twilioCodeConcurrentLimit:
		return ErrOTPResendTooSoon
	case code == twilioCodeInvalidParameter:
		return ErrInvalidPhone
	default:
		t.logger.Warn("twilio verification start failed", "op", "start", "http_status", status, "twilio_code", code)
		return ErrOTPProviderUnavailable
	}
}

// CheckVerification submits code for phone to the verification-check
// endpoint. Twilio reports a wrong-but-checkable code as a 200 with status
// "pending", and an expired, consumed, or never-started verification as a
// 404 — both are mapped onto the existing auth error contract rather than
// surfaced as vendor statuses.
func (t *TwilioVerifier) CheckVerification(ctx context.Context, phone, code string) error {
	status, body, err := t.post(ctx, "check", "/v2/Services/"+t.serviceSID+"/VerificationCheck", url.Values{
		"To":   {phone},
		"Code": {code},
	})
	if err != nil {
		return err
	}
	if status/100 == 2 {
		var res struct {
			Status string `json:"status"`
		}
		if jsonErr := json.Unmarshal(body, &res); jsonErr != nil {
			t.logger.Warn("twilio verification check answered an unparseable body", "op", "check", "http_status", status)
			return ErrOTPProviderUnavailable
		}
		switch res.Status {
		case "approved":
			return nil
		case "pending":
			// checkable but wrong code — twilio's own attempt counter
			// advanced; after its limit the next check answers 60202.
			return ErrOTPCodeMismatch
		case "canceled":
			return ErrOTPExpired
		default:
			t.logger.Warn("twilio verification check answered an unknown status", "op", "check", "http_status", status)
			return ErrOTPProviderUnavailable
		}
	}

	twCode := twilioErrorCode(body)
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		t.logger.Error("twilio verify rejected the configured credentials", "op", "check", "http_status", status, "twilio_code", twCode)
		return ErrOTPProviderUnavailable
	case status == http.StatusNotFound:
		// 20404: no pending verification for this number — expired,
		// already approved (a replay), or never requested. The existing
		// contract's expired/replayed response covers all three.
		return ErrOTPExpired
	case status == http.StatusTooManyRequests || twCode == twilioCodeMaxCheckAttempts:
		return ErrOTPTooManyAttempts
	case twCode == twilioCodeInvalidParameter:
		return ErrInvalidPhone
	default:
		t.logger.Warn("twilio verification check failed", "op", "check", "http_status", status, "twilio_code", twCode)
		return ErrOTPProviderUnavailable
	}
}

// post runs one form-encoded request against the verify api with at most
// one retry. Retry happens only when repeating is known to be safe: a 5xx
// response, or a dial error (the request never reached twilio). A
// per-attempt timeout or any other mid-flight failure is not retried —
// twilio may already have acted on the request. Cancellation of the
// incoming ctx always wins immediately.
//
// Transport errors are never logged verbatim: a *url.Error's message
// embeds the full request url, which contains the verify service sid.
func (t *TwilioVerifier) post(ctx context.Context, op, path string, form url.Values) (int, []byte, error) {
	const maxAttempts = 2
	for attempt := 1; ; attempt++ {
		status, body, err := t.postOnce(ctx, path, form)
		if err == nil && status < 500 {
			return status, body, nil
		}
		if ctx.Err() != nil {
			return 0, nil, ctx.Err()
		}
		if err != nil && !isDialError(err) {
			// timeout or mid-flight failure — repeating is not safe.
			t.logger.Warn("twilio verify request failed", "op", op, "attempt", attempt, "error_kind", errorKind(err))
			return 0, nil, ErrOTPProviderUnavailable
		}
		if attempt >= maxAttempts {
			t.logger.Warn("twilio verify unavailable after retry", "op", op, "http_status", status, "error_kind", errorKind(err))
			return 0, nil, ErrOTPProviderUnavailable
		}
		if t.retryDelay > 0 {
			timer := time.NewTimer(t.retryDelay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return 0, nil, ctx.Err()
			case <-timer.C:
			}
		}
	}
}

func (t *TwilioVerifier) postOnce(ctx context.Context, path string, form url.Values) (int, []byte, error) {
	reqCtx, cancel := context.WithTimeout(ctx, t.timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, t.baseURL+path, strings.NewReader(form.Encode()))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetBasicAuth(t.accountSID, t.authToken)

	resp, err := t.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, twilioMaxResponseBytes))
	if err != nil {
		return 0, nil, err
	}
	return resp.StatusCode, body, nil
}

// twilioErrorCode extracts the numeric twilio error code from an error
// body, or 0 when there is none to extract.
func twilioErrorCode(body []byte) int {
	var res struct {
		Code int `json:"code"`
	}
	if err := json.Unmarshal(body, &res); err != nil {
		return 0
	}
	return res.Code
}

// isDialError reports whether err failed while establishing the
// connection — the one transport failure where the request certainly never
// reached twilio, making a retry safe.
func isDialError(err error) bool {
	var opErr *net.OpError
	return errors.As(err, &opErr) && opErr.Op == "dial"
}

// errorKind is the only representation of a transport error that may be
// logged (see post's redaction note).
func errorKind(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case isDialError(err):
		return "dial"
	default:
		return "transport"
	}
}
