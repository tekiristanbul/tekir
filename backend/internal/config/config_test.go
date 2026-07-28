package config

import (
	"strings"
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
	if cfg.OTPProvider != "" {
		t.Errorf("expected no raw otp provider default, got %q", cfg.OTPProvider)
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

// TestResolveOTPProvider covers issue #59's fail-closed provider
// selection: fake is only reachable under an explicit APP_ENV=development,
// every non-development environment (production, unset, unrecognized)
// accepts twilio exclusively, and twilio always requires its three
// settings. No case ever resolves an unavailable/misconfigured twilio to
// fake.
func TestResolveOTPProvider(t *testing.T) {
	twilio := Config{
		TwilioAccountSID:       "sid-placeholder",
		TwilioAuthToken:        "token-placeholder",
		TwilioVerifyServiceSID: "verify-sid-placeholder",
	}

	cases := []struct {
		name     string
		cfg      Config
		want     string
		wantErr  bool
		errNames []string // substrings the error must mention
	}{
		{name: "development defaults to fake when unset", cfg: Config{AppEnv: AppEnvDevelopment}, want: OTPProviderFake},
		{name: "development explicit fake", cfg: Config{AppEnv: AppEnvDevelopment, OTPProvider: OTPProviderFake}, want: OTPProviderFake},
		{name: "development twilio with full settings", cfg: func() Config { c := twilio; c.AppEnv = AppEnvDevelopment; c.OTPProvider = OTPProviderTwilio; return c }(), want: OTPProviderTwilio},
		{name: "development unknown provider rejected", cfg: Config{AppEnv: AppEnvDevelopment, OTPProvider: "carrier-pigeon"}, wantErr: true},
		{name: "production twilio with full settings", cfg: func() Config { c := twilio; c.AppEnv = AppEnvProduction; c.OTPProvider = OTPProviderTwilio; return c }(), want: OTPProviderTwilio},
		{name: "production rejects fake", cfg: Config{AppEnv: AppEnvProduction, OTPProvider: OTPProviderFake}, wantErr: true},
		{name: "production rejects unset", cfg: Config{AppEnv: AppEnvProduction}, wantErr: true},
		{name: "production rejects unknown", cfg: Config{AppEnv: AppEnvProduction, OTPProvider: "carrier-pigeon"}, wantErr: true},
		{name: "unset environment behaves as production for fake", cfg: Config{OTPProvider: OTPProviderFake}, wantErr: true},
		{name: "unset environment behaves as production for unset provider", cfg: Config{}, wantErr: true},
		{name: "unset environment still accepts configured twilio", cfg: func() Config { c := twilio; c.OTPProvider = OTPProviderTwilio; return c }(), want: OTPProviderTwilio},
		{name: "unrecognized environment behaves as production", cfg: Config{AppEnv: "staging", OTPProvider: OTPProviderFake}, wantErr: true},
		{name: "twilio missing account sid", cfg: func() Config {
			c := twilio
			c.AppEnv = AppEnvDevelopment
			c.OTPProvider = OTPProviderTwilio
			c.TwilioAccountSID = ""
			return c
		}(), wantErr: true, errNames: []string{"TWILIO_ACCOUNT_SID"}},
		{name: "twilio missing auth token", cfg: func() Config {
			c := twilio
			c.AppEnv = AppEnvDevelopment
			c.OTPProvider = OTPProviderTwilio
			c.TwilioAuthToken = ""
			return c
		}(), wantErr: true, errNames: []string{"TWILIO_AUTH_TOKEN"}},
		{name: "twilio missing verify service sid", cfg: func() Config {
			c := twilio
			c.AppEnv = AppEnvProduction
			c.OTPProvider = OTPProviderTwilio
			c.TwilioVerifyServiceSID = ""
			return c
		}(), wantErr: true, errNames: []string{"TWILIO_VERIFY_SERVICE_SID"}},
		{name: "twilio missing everything names all three", cfg: Config{AppEnv: AppEnvProduction, OTPProvider: OTPProviderTwilio}, wantErr: true, errNames: []string{"TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_VERIFY_SERVICE_SID"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := tc.cfg.ResolveOTPProvider()
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got provider %q", got)
				}
				for _, name := range tc.errNames {
					if !strings.Contains(err.Error(), name) {
						t.Errorf("expected error to mention %s, got %q", name, err)
					}
				}
				// configured values are secrets — an error may name the
				// variable but must never echo its value.
				for _, secret := range []string{tc.cfg.TwilioAccountSID, tc.cfg.TwilioAuthToken, tc.cfg.TwilioVerifyServiceSID} {
					if secret != "" && strings.Contains(err.Error(), secret) {
						t.Errorf("error leaks a configured value: %q", err)
					}
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Errorf("expected provider %q, got %q", tc.want, got)
			}
		})
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
