package service

import (
	"context"
	"errors"
)

// ErrOTPProviderUnavailable means the external otp verification provider
// could not be reached, timed out, or answered abnormally. It is retryable
// from the caller's point of view, and deliberately surfaces to a client as
// the same generic internal error any other backend dependency outage
// (e.g. the database) does — the public contract never names or hints at
// the vendor behind it (issue #59).
var ErrOTPProviderUnavailable = errors.New("otp provider unavailable")

// OTPVerificationProvider is the boundary for an external verification
// service that owns the one-time code end to end — generation, delivery,
// expiry, and attempt limiting (issue #59; twilio verify is the
// mvp-selected vendor, see docs/architecture/backend.md). It exists
// alongside SmsSender rather than replacing it because the two boundaries
// have different shapes: SmsSender only delivers a code this backend
// generated, stored, and checks locally (the deterministic fake path),
// while an external provider like twilio verify never reveals the code to
// the backend at all, so verification must round-trip through it too.
//
// Implementations map every provider outcome onto the existing auth error
// set (ErrInvalidPhone, ErrOTPCodeMismatch, ErrOTPExpired,
// ErrOTPTooManyAttempts, ErrOTPResendTooSoon, ErrOTPProviderUnavailable) —
// vendor status codes never leak past this interface.
type OTPVerificationProvider interface {
	// StartVerification asks the provider to generate and deliver a code
	// to phone (already normalized to E.164).
	StartVerification(ctx context.Context, phone string) error
	// CheckVerification asks the provider whether code is the valid,
	// unexpired code it last delivered to phone. A nil return is the only
	// success signal.
	CheckVerification(ctx context.Context, phone, code string) error
}
