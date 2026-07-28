package main

import "testing"

func TestNewNotificationSender_Fake(t *testing.T) {
	sender, err := newNotificationSender("fake")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sender == nil {
		t.Fatal("expected a non-nil sender")
	}
}

// TestNewNotificationSender_FailsClosed proves an unset or unrecognized
// NOTIFICATION_PROVIDER fails startup rather than silently running the
// fake provider (issue #78's explicit fail-closed constraint) — unlike
// cmd/api's newObjectStore, which does default an empty provider to
// "fake" via config.Load()'s own fallback. OTP_PROVIDER stopped
// defaulting unconditionally in issue #59: config.ResolveOTPProvider only
// defaults it to "fake" under an explicit APP_ENV=development.
func TestNewNotificationSender_FailsClosed(t *testing.T) {
	for _, provider := range []string{"", "fcm", "twilio-push", "FAKE"} {
		t.Run(provider, func(t *testing.T) {
			if _, err := newNotificationSender(provider); err == nil {
				t.Fatalf("expected an error for provider %q, got nil", provider)
			}
		})
	}
}
