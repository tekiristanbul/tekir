package config

import (
	"testing"
	"time"
)

func TestLoad_RequiresDatabaseURL(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	t.Setenv("JWT_SIGNING_KEY", "test-signing-key")

	if _, err := Load(); err == nil {
		t.Fatal("expected error when DATABASE_URL is unset")
	}
}

func TestLoad_RequiresJWTSigningKey(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SIGNING_KEY", "")

	if _, err := Load(); err == nil {
		t.Fatal("expected error when JWT_SIGNING_KEY is unset")
	}
}

func TestLoad_Defaults(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SIGNING_KEY", "test-signing-key")
	t.Setenv("PORT", "")
	t.Setenv("LOG_LEVEL", "")
	t.Setenv("ACCESS_TOKEN_TTL", "")
	t.Setenv("REFRESH_TOKEN_TTL", "")
	t.Setenv("OTP_CODE_TTL", "")
	t.Setenv("OTP_MAX_ATTEMPTS", "")
	t.Setenv("OTP_RESEND_COOLDOWN", "")
	t.Setenv("OTP_PROVIDER", "")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.Port != "8080" {
		t.Errorf("expected default port 8080, got %q", cfg.Port)
	}
	if cfg.LogLevel != "info" {
		t.Errorf("expected default log level info, got %q", cfg.LogLevel)
	}
	if cfg.AccessTokenTTL != 15*time.Minute {
		t.Errorf("expected default access token ttl 15m, got %v", cfg.AccessTokenTTL)
	}
	if cfg.RefreshTokenTTL != 30*24*time.Hour {
		t.Errorf("expected default refresh token ttl 30d, got %v", cfg.RefreshTokenTTL)
	}
	if cfg.OTPCodeTTL != 5*time.Minute {
		t.Errorf("expected default otp code ttl 5m, got %v", cfg.OTPCodeTTL)
	}
	if cfg.OTPMaxAttempts != 5 {
		t.Errorf("expected default otp max attempts 5, got %d", cfg.OTPMaxAttempts)
	}
	if cfg.OTPResendCooldown != 60*time.Second {
		t.Errorf("expected default otp resend cooldown 60s, got %v", cfg.OTPResendCooldown)
	}
	if cfg.OTPProvider != "fake" {
		t.Errorf("expected default otp provider fake, got %q", cfg.OTPProvider)
	}
}

// TestLoad_NotificationProviderHasNoDefault proves NotificationProvider,
// unlike OTPProvider/ObjectStorageProvider, is empty (not "fake") when
// unset — issue #78 requires notification delivery to fail closed rather
// than silently default to the dev/test provider in a production
// deployment that forgot to set NOTIFICATION_PROVIDER. The empty-string
// case is rejected by cmd/notifier's newNotificationSender, not here —
// Load() itself never fails on it, mirroring how OTP_PROVIDER/
// OBJECT_STORAGE_PROVIDER validation also lives at the cmd/api call site.
func TestLoad_NotificationProviderHasNoDefault(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SIGNING_KEY", "test-signing-key")
	t.Setenv("NOTIFICATION_PROVIDER", "")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.NotificationProvider != "" {
		t.Errorf("expected no default notification provider, got %q", cfg.NotificationProvider)
	}
}

func TestLoad_NotificationProviderOverride(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SIGNING_KEY", "test-signing-key")
	t.Setenv("NOTIFICATION_PROVIDER", "fake")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.NotificationProvider != "fake" {
		t.Errorf("expected notification provider fake, got %q", cfg.NotificationProvider)
	}
}

func TestLoad_OverridesTTLsAndProvider(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SIGNING_KEY", "test-signing-key")
	t.Setenv("ACCESS_TOKEN_TTL", "1m")
	t.Setenv("OTP_MAX_ATTEMPTS", "3")
	t.Setenv("OTP_PROVIDER", "twilio")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.AccessTokenTTL != time.Minute {
		t.Errorf("expected overridden access token ttl 1m, got %v", cfg.AccessTokenTTL)
	}
	if cfg.OTPMaxAttempts != 3 {
		t.Errorf("expected overridden otp max attempts 3, got %d", cfg.OTPMaxAttempts)
	}
	if cfg.OTPProvider != "twilio" {
		t.Errorf("expected overridden otp provider twilio, got %q", cfg.OTPProvider)
	}
}
