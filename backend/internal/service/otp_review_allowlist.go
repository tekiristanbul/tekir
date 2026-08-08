package service

import (
	"context"
	"errors"
	"fmt"
)

// ReviewAllowlistOTPProvider wraps an OTPVerificationProvider with a small,
// env-configured bypass for app-store review (issue #184): twilio verify
// can't reliably reach a reviewer-controlled number, so a fixed list of
// e.164 numbers gets a fixed code instead of a real sms round trip. Every
// other number is passed straight through to the wrapped provider
// unchanged. This is only ever constructed when both
// OTP_REVIEW_TEST_NUMBERS and OTP_REVIEW_TEST_CODE are configured (see
// config.ResolveOTPReviewAllowlist) — there is no path from this type to a
// global bypass.
type ReviewAllowlistOTPProvider struct {
	underlying OTPVerificationProvider
	code       string
	numbers    map[string]struct{}
}

// NewReviewAllowlistOTPProvider builds the wrapper, normalizing every
// configured number through NormalizePhone so it compares equal to the
// already-normalized phone RequestOTP/VerifyOTP pass down. An unparseable
// number or empty code fails construction — issue #184's allowlist is
// small and reviewer-controlled, so a typo should stop startup, not be
// silently dropped.
func NewReviewAllowlistOTPProvider(underlying OTPVerificationProvider, rawNumbers []string, code string) (*ReviewAllowlistOTPProvider, error) {
	if code == "" {
		return nil, errors.New("otp review allowlist: OTP_REVIEW_TEST_CODE must not be empty")
	}

	numbers := make(map[string]struct{}, len(rawNumbers))
	for _, raw := range rawNumbers {
		phone, err := NormalizePhone(raw)
		if err != nil {
			return nil, fmt.Errorf("otp review allowlist: invalid OTP_REVIEW_TEST_NUMBERS entry %q: %w", raw, err)
		}
		numbers[phone] = struct{}{}
	}
	if len(numbers) == 0 {
		return nil, errors.New("otp review allowlist: OTP_REVIEW_TEST_NUMBERS must list at least one phone number")
	}

	return &ReviewAllowlistOTPProvider{underlying: underlying, code: code, numbers: numbers}, nil
}

// StartVerification skips the wrapped provider entirely for an allowlisted
// phone — no twilio call, no real sms, no cost, no dependency on twilio
// reachability (issue #184) — and delegates unchanged for every other
// number.
func (p *ReviewAllowlistOTPProvider) StartVerification(ctx context.Context, phone string) error {
	if _, ok := p.numbers[phone]; ok {
		return nil
	}
	return p.underlying.StartVerification(ctx, phone)
}

// CheckVerification accepts only the exact configured fixed code for an
// allowlisted phone, never falling back to the wrapped provider — the
// wrapped provider was never asked to start a verification for this number,
// so it has nothing to check against. Every other number is checked by the
// wrapped provider unchanged.
func (p *ReviewAllowlistOTPProvider) CheckVerification(ctx context.Context, phone, code string) error {
	if _, ok := p.numbers[phone]; ok {
		if code != p.code {
			return ErrOTPCodeMismatch
		}
		return nil
	}
	return p.underlying.CheckVerification(ctx, phone, code)
}
