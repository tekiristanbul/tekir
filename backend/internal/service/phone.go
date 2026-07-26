package service

import (
	"errors"
	"strings"
)

// ErrInvalidPhone means the presented phone number isn't a well-formed
// Turkish mobile number in the format the prototype's login screen already
// collects (a fixed +90 prefix plus a 10-digit, 5xx-leading subscriber
// number — see prototype/app.js's login screen).
var ErrInvalidPhone = errors.New("invalid phone number")

// turkishMobileDigits is the length of a Turkish mobile subscriber number
// without the country code, e.g. "5xx xxx xx xx" → 10 digits.
const turkishMobileDigits = 10

// NormalizePhone strips formatting from a phone number and returns it in
// E.164 form (+90XXXXXXXXXX). It accepts a bare 10-digit subscriber number
// (matching the prototype's "+90" fixed-prefix input field) or one already
// carrying a "+90", "90", or leading "0" prefix. Anything else — wrong
// length, a non-Turkish country code, non-digit characters — is rejected
// rather than guessed at.
func NormalizePhone(raw string) (string, error) {
	digits := onlyDigits(raw)

	switch {
	case len(digits) == turkishMobileDigits && strings.HasPrefix(digits, "5"):
		// bare subscriber number, e.g. "5xx xxx xx xx".
	case len(digits) == turkishMobileDigits+1 && strings.HasPrefix(digits, "05"):
		// leading trunk-prefix zero, e.g. "05xx xxx xx xx".
		digits = digits[1:]
	case len(digits) == turkishMobileDigits+2 && strings.HasPrefix(digits, "905"):
		// country code without "+", e.g. "905xx xxx xx xx".
		digits = digits[2:]
	default:
		return "", ErrInvalidPhone
	}

	return "+90" + digits, nil
}

func onlyDigits(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}
