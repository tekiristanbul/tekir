package service_test

import (
	"errors"
	"testing"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

func TestNormalizePhone_BareSubscriberNumber(t *testing.T) {
	got, err := service.NormalizePhone("532 111 22 33")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "+905321112233" {
		t.Errorf("expected +905321112233, got %q", got)
	}
}

func TestNormalizePhone_LeadingTrunkZero(t *testing.T) {
	got, err := service.NormalizePhone("0532 111 22 33")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "+905321112233" {
		t.Errorf("expected +905321112233, got %q", got)
	}
}

func TestNormalizePhone_CountryCodeNoPlus(t *testing.T) {
	got, err := service.NormalizePhone("905321112233")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "+905321112233" {
		t.Errorf("expected +905321112233, got %q", got)
	}
}

func TestNormalizePhone_FullE164AlreadyNormalized(t *testing.T) {
	got, err := service.NormalizePhone("+90 532 111 22 33")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "+905321112233" {
		t.Errorf("expected +905321112233, got %q", got)
	}
}

func TestNormalizePhone_Invalid(t *testing.T) {
	cases := []string{
		"",
		"123",
		"532 111 22",    // too short
		"5321112233444", // too long
		"4321112233",    // doesn't start with 5
		"not a phone at all",
		"+1 555 111 2233", // non-Turkish country code
	}
	for _, c := range cases {
		t.Run(c, func(t *testing.T) {
			_, err := service.NormalizePhone(c)
			if !errors.Is(err, service.ErrInvalidPhone) {
				t.Errorf("expected ErrInvalidPhone for %q, got %v", c, err)
			}
		})
	}
}
