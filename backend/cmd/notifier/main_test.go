package main

import (
	"path/filepath"
	"testing"

	"github.com/tekiristanbul/tekir/backend/internal/config"
)

func TestNewNotificationSender_Fake(t *testing.T) {
	sender, err := newNotificationSender(config.NotificationProviderFake, config.Config{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sender == nil {
		t.Fatal("expected a non-nil sender")
	}
}

// TestNewNotificationSender_FailsClosed proves an unrecognized provider
// value still fails construction even if it somehow slipped past
// config.ResolveNotificationProvider — the fail-closed posture (issue #78,
// extended by issue #84) holds at both layers. The full unset/unknown/
// fake-in-production matrix lives in config's TestResolveNotificationProvider,
// which run() consults before this constructor is ever reached.
func TestNewNotificationSender_FailsClosed(t *testing.T) {
	for _, provider := range []string{"", "twilio-push", "FAKE", "FCM"} {
		t.Run(provider, func(t *testing.T) {
			if _, err := newNotificationSender(provider, config.Config{}); err == nil {
				t.Fatalf("expected an error for provider %q, got nil", provider)
			}
		})
	}
}

// TestNewNotificationSender_FCMIncompleteCredentialsFailStartup proves
// selecting fcm with missing or unreadable credentials fails construction
// outright — it must never degrade to the fake provider (issue #84).
func TestNewNotificationSender_FCMIncompleteCredentialsFailStartup(t *testing.T) {
	if _, err := newNotificationSender(config.NotificationProviderFCM, config.Config{}); err == nil {
		t.Fatal("expected an error for fcm without credentials, got nil")
	}
	cfg := config.Config{FCMCredentialsFile: filepath.Join(t.TempDir(), "missing.json")}
	if _, err := newNotificationSender(config.NotificationProviderFCM, cfg); err == nil {
		t.Fatal("expected an error for fcm with an unreadable credentials file, got nil")
	}
}
