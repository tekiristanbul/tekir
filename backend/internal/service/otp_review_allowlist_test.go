package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// TestNewReviewAllowlistOTPProvider_Validation covers issue #184's
// fail-closed construction: an empty code or an unparseable number must
// stop construction rather than silently produce a partial/degraded
// allowlist.
func TestNewReviewAllowlistOTPProvider_Validation(t *testing.T) {
	underlying := &fakeExternalOTPProvider{}

	if _, err := service.NewReviewAllowlistOTPProvider(underlying, []string{"5339998877"}, ""); err == nil {
		t.Error("expected an error for an empty code")
	}
	if _, err := service.NewReviewAllowlistOTPProvider(underlying, []string{"not-a-phone-number"}, "123456"); err == nil {
		t.Error("expected an error for an unparseable phone number")
	}
	if _, err := service.NewReviewAllowlistOTPProvider(underlying, nil, "123456"); err == nil {
		t.Error("expected an error for an empty number list")
	}
	if _, err := service.NewReviewAllowlistOTPProvider(underlying, []string{"5339998877"}, "123456"); err != nil {
		t.Errorf("unexpected error constructing a valid allowlist: %v", err)
	}
}

// TestReviewAllowlistOTPProvider_AllowlistedNumber covers the two
// acceptance criteria in issue #184: StartVerification never reaches the
// wrapped provider for an allowlisted number, and CheckVerification accepts
// only the exact configured fixed code for it.
func TestReviewAllowlistOTPProvider_AllowlistedNumber(t *testing.T) {
	underlying := &fakeExternalOTPProvider{}
	p, err := service.NewReviewAllowlistOTPProvider(underlying, []string{"5339998877"}, "123456")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if err := p.StartVerification(context.Background(), "+905339998877"); err != nil {
		t.Errorf("expected nil error for an allowlisted number, got %v", err)
	}
	if len(underlying.startCalls) != 0 {
		t.Errorf("expected the wrapped provider to never be called, got calls %v", underlying.startCalls)
	}

	if err := p.CheckVerification(context.Background(), "+905339998877", "000000"); !errors.Is(err, service.ErrOTPCodeMismatch) {
		t.Errorf("expected ErrOTPCodeMismatch for the wrong fixed code, got %v", err)
	}
	if err := p.CheckVerification(context.Background(), "+905339998877", "123456"); err != nil {
		t.Errorf("expected nil error for the exact configured fixed code, got %v", err)
	}
	if len(underlying.checkCalls) != 0 {
		t.Errorf("expected the wrapped provider to never be called, got calls %v", underlying.checkCalls)
	}
}

// TestReviewAllowlistOTPProvider_OtherNumbersPassThrough covers issue
// #184's "outside that allowlist, behavior is unchanged" requirement: any
// number not in the list is delegated to the wrapped provider unchanged, in
// both directions.
func TestReviewAllowlistOTPProvider_OtherNumbersPassThrough(t *testing.T) {
	underlying := &fakeExternalOTPProvider{}
	p, err := service.NewReviewAllowlistOTPProvider(underlying, []string{"5339998877"}, "123456")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if err := p.StartVerification(context.Background(), "+905321112233"); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if len(underlying.startCalls) != 1 || underlying.startCalls[0] != "+905321112233" {
		t.Errorf("expected the wrapped provider to be called with the number, got calls %v", underlying.startCalls)
	}

	underlying.checkErr = service.ErrOTPCodeMismatch
	if err := p.CheckVerification(context.Background(), "+905321112233", "123456"); !errors.Is(err, service.ErrOTPCodeMismatch) {
		t.Errorf("expected the wrapped provider's error to pass through, got %v", err)
	}
	if len(underlying.checkCalls) != 1 {
		t.Errorf("expected the wrapped provider to be called, got calls %v", underlying.checkCalls)
	}
}
