// Package config loads runtime configuration from the environment.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// AppEnv values ResolveOTPProvider recognizes. Anything else — including
// unset — is treated as production, so a deployment that forgets APP_ENV
// fails closed instead of silently unlocking development conveniences.
const (
	AppEnvDevelopment = "development"
	AppEnvProduction  = "production"
)

// OTPProvider values ResolveOTPProvider can return.
const (
	OTPProviderFake   = "fake"
	OTPProviderTwilio = "twilio"
)

// NotificationProvider values ResolveNotificationProvider can return.
const (
	NotificationProviderFake = "fake"
	NotificationProviderFCM  = "fcm"
)

type Config struct {
	Port            string
	DatabaseURL     string
	LogLevel        string
	ShutdownTimeout time.Duration
	CORSOrigins     []string

	// AppEnv (APP_ENV) declares which environment this process runs in.
	// Only the OTP provider selection consumes it today (issue #59): the
	// fake provider default is unlocked exclusively by an explicit
	// "development". No default — see the AppEnv* constants.
	AppEnv string

	// JWTSigningKey signs and validates access-token JWTs (issue #58).
	// Required: an empty or default key would let anyone forge a session.
	JWTSigningKey string
	// AccessTokenTTL/RefreshTokenTTL bound how long an access token and a
	// refresh token stay valid after issuance.
	AccessTokenTTL  time.Duration
	RefreshTokenTTL time.Duration
	// OTPCodeTTL/OTPMaxAttempts/OTPResendCooldown bound how long an otp
	// code stays valid, how many wrong guesses it tolerates, and how soon
	// a new code may be requested for the same phone number.
	OTPCodeTTL        time.Duration
	OTPMaxAttempts    int32
	OTPResendCooldown time.Duration
	// OTPProvider selects the otp implementation: "fake" (the
	// deterministic, no-network, log-only provider — issue #58) or
	// "twilio" (twilio verify — issue #59). Raw environment value; the
	// environment-aware defaulting and validation live in
	// ResolveOTPProvider, which cmd/api calls at startup. Deliberately no
	// unconditional "fake" default anymore: fake is only ever a default
	// under an explicit APP_ENV=development.
	OTPProvider string

	// TwilioAccountSID/TwilioAuthToken/TwilioVerifyServiceSID configure
	// the twilio verify adapter and are required when OTPProvider is
	// "twilio" (issue #59). Deployment secrets — values are never logged
	// or echoed in errors. TWILIO_NUMBER is deliberately not read: twilio
	// verify addresses a verify service sid, not a sender number.
	TwilioAccountSID       string
	TwilioAuthToken        string
	TwilioVerifyServiceSID string

	// ObjectStorageProvider selects the ObjectStore implementation for
	// media uploads (issue #70). Only "fake" (a deterministic, local-disk
	// provider — see docs/architecture/backend.md) is wired; a real
	// s3-compatible provider (digitalocean spaces) is future work, mirroring
	// OTPProvider's "fake"-only status.
	ObjectStorageProvider string
	// MediaLocalDir is where FakeObjectStore reads/writes uploaded media
	// when ObjectStorageProvider is "fake". Unused by any other provider.
	MediaLocalDir string
	// MediaPublicBaseURL is prepended to the object key FakeObjectStore
	// returns, so primary_photo/media urls are always absolute — matching
	// what a real s3-compatible provider would return on its own — rather
	// than a host-relative path a client can't resolve on its own. Unused
	// by any other provider.
	MediaPublicBaseURL string
	// MediaMaxBytes bounds an uploaded file's size before it's ever decoded,
	// so a request can't force the server to decompress an arbitrarily
	// large image (issue #70's malformed/oversized-media rejection).
	MediaMaxBytes int

	// NotificationProvider selects the NotificationSender implementation
	// cmd/notifier uses: "fake" (the deterministic, log-only, no-network
	// dev/test provider — issue #78) or "fcm" (firebase cloud messaging
	// http v1 — issue #84). Raw environment value; the environment-aware
	// defaulting and validation live in ResolveNotificationProvider, which
	// cmd/notifier calls at startup — exactly the OTPProvider/
	// ResolveOTPProvider split (issue #59). Like OTP_PROVIDER, "fake" is
	// only ever a default under an explicit APP_ENV=development; production
	// fails closed on unset/unknown/incomplete configuration.
	NotificationProvider string

	// FCMCredentialsFile (FCM_CREDENTIALS_FILE) is the path to the Google
	// service-account json the fcm sender authenticates with (fcm http v1
	// — issue #84; legacy server keys are deliberately unsupported).
	// Required when NotificationProvider is "fcm". A path, never inline
	// json: the file lives in deployment secrets and its contents are
	// never logged or echoed in errors. The firebase project id comes from
	// the file's project_id field, so no separate project-id variable
	// exists to drift out of sync with the credentials.
	FCMCredentialsFile string
}

func Load() (Config, error) {
	cfg := Config{
		Port:            getEnv("PORT", "8080"),
		DatabaseURL:     os.Getenv("DATABASE_URL"),
		LogLevel:        getEnv("LOG_LEVEL", "info"),
		ShutdownTimeout: 10 * time.Second,
		CORSOrigins:     splitCSV(getEnv("CORS_ALLOWED_ORIGINS", "http://localhost:*,http://127.0.0.1:*")),

		JWTSigningKey:     os.Getenv("JWT_SIGNING_KEY"),
		AccessTokenTTL:    getEnvDuration("ACCESS_TOKEN_TTL", 15*time.Minute),
		RefreshTokenTTL:   getEnvDuration("REFRESH_TOKEN_TTL", 30*24*time.Hour),
		OTPCodeTTL:        getEnvDuration("OTP_CODE_TTL", 5*time.Minute),
		OTPMaxAttempts:    getEnvInt32("OTP_MAX_ATTEMPTS", 5),
		OTPResendCooldown: getEnvDuration("OTP_RESEND_COOLDOWN", 60*time.Second),
		// raw values only — ResolveOTPProvider applies the
		// environment-aware default and validation (issue #59), and only
		// cmd/api calls it, so cmd/notifier keeps starting without any
		// otp configuration.
		AppEnv:                 os.Getenv("APP_ENV"),
		OTPProvider:            os.Getenv("OTP_PROVIDER"),
		TwilioAccountSID:       os.Getenv("TWILIO_ACCOUNT_SID"),
		TwilioAuthToken:        os.Getenv("TWILIO_AUTH_TOKEN"),
		TwilioVerifyServiceSID: os.Getenv("TWILIO_VERIFY_SERVICE_SID"),

		ObjectStorageProvider: getEnv("OBJECT_STORAGE_PROVIDER", "fake"),
		MediaLocalDir:         getEnv("MEDIA_LOCAL_DIR", "./data/media"),
		MediaMaxBytes:         getEnvInt("MEDIA_MAX_BYTES", 8*1024*1024),

		// raw values only — ResolveNotificationProvider applies the
		// environment-aware default and validation (issue #84), keeping
		// issue #78's fail-closed posture: production never silently runs
		// the fake provider because an operator forgot to set this.
		NotificationProvider: os.Getenv("NOTIFICATION_PROVIDER"),
		FCMCredentialsFile:   os.Getenv("FCM_CREDENTIALS_FILE"),
	}
	cfg.MediaPublicBaseURL = getEnv("MEDIA_PUBLIC_BASE_URL", "http://localhost:"+cfg.Port)

	if cfg.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.JWTSigningKey == "" {
		return Config{}, fmt.Errorf("JWT_SIGNING_KEY is required")
	}

	return cfg, nil
}

// ResolveOTPProvider decides which otp provider cmd/api runs with (issue
// #59) and validates the selection is complete. The rules are fail-closed:
//
//   - "fake" is only reachable under an explicit APP_ENV=development —
//     as the default when OTP_PROVIDER is unset, or when set explicitly.
//   - any other environment (production, unset, or unrecognized) rejects
//     fake, unset, and unknown providers outright; only "twilio" is
//     accepted there.
//   - "twilio" additionally requires TWILIO_ACCOUNT_SID,
//     TWILIO_AUTH_TOKEN, and TWILIO_VERIFY_SERVICE_SID in every
//     environment; any missing one fails resolution, naming the missing
//     variables but never echoing a configured value.
//
// There is intentionally no path that degrades a selected or required
// twilio provider to fake — misconfiguration stops startup instead.
func (c Config) ResolveOTPProvider() (string, error) {
	dev := c.AppEnv == AppEnvDevelopment

	provider := c.OTPProvider
	if provider == "" && dev {
		provider = OTPProviderFake
	}

	switch provider {
	case OTPProviderFake:
		if !dev {
			return "", fmt.Errorf("OTP_PROVIDER %q is only allowed with APP_ENV=%s (production requires OTP_PROVIDER=%s)", provider, AppEnvDevelopment, OTPProviderTwilio)
		}
		return OTPProviderFake, nil
	case OTPProviderTwilio:
		var missing []string
		if c.TwilioAccountSID == "" {
			missing = append(missing, "TWILIO_ACCOUNT_SID")
		}
		if c.TwilioAuthToken == "" {
			missing = append(missing, "TWILIO_AUTH_TOKEN")
		}
		if c.TwilioVerifyServiceSID == "" {
			missing = append(missing, "TWILIO_VERIFY_SERVICE_SID")
		}
		if len(missing) > 0 {
			return "", fmt.Errorf("OTP_PROVIDER=%s requires %s", OTPProviderTwilio, strings.Join(missing, ", "))
		}
		return OTPProviderTwilio, nil
	case "":
		return "", fmt.Errorf("OTP_PROVIDER is required (set APP_ENV=%s for the local %q default, or OTP_PROVIDER=%s)", AppEnvDevelopment, OTPProviderFake, OTPProviderTwilio)
	default:
		return "", fmt.Errorf("unsupported OTP_PROVIDER %q (%q with APP_ENV=%s, or %q)", provider, OTPProviderFake, AppEnvDevelopment, OTPProviderTwilio)
	}
}

// ResolveNotificationProvider decides which notification provider
// cmd/notifier runs with (issue #84) and validates the selection is
// complete — the same fail-closed shape as ResolveOTPProvider (issue #59):
//
//   - "fake" is only reachable under an explicit APP_ENV=development —
//     as the default when NOTIFICATION_PROVIDER is unset, or when set
//     explicitly.
//   - any other environment (production, unset, or unrecognized) rejects
//     fake, unset, and unknown providers outright; only "fcm" is accepted
//     there.
//   - "fcm" additionally requires FCM_CREDENTIALS_FILE in every
//     environment; a missing value fails resolution, naming the variable
//     but never echoing a configured value.
//
// There is intentionally no path that degrades a selected or required fcm
// provider to fake — misconfiguration stops startup instead (issue #84's
// no-silent-fallback constraint, inherited from issue #78).
func (c Config) ResolveNotificationProvider() (string, error) {
	dev := c.AppEnv == AppEnvDevelopment

	provider := c.NotificationProvider
	if provider == "" && dev {
		provider = NotificationProviderFake
	}

	switch provider {
	case NotificationProviderFake:
		if !dev {
			return "", fmt.Errorf("NOTIFICATION_PROVIDER %q is only allowed with APP_ENV=%s (production requires NOTIFICATION_PROVIDER=%s)", provider, AppEnvDevelopment, NotificationProviderFCM)
		}
		return NotificationProviderFake, nil
	case NotificationProviderFCM:
		if c.FCMCredentialsFile == "" {
			return "", fmt.Errorf("NOTIFICATION_PROVIDER=%s requires FCM_CREDENTIALS_FILE", NotificationProviderFCM)
		}
		return NotificationProviderFCM, nil
	case "":
		return "", fmt.Errorf("NOTIFICATION_PROVIDER is required (set APP_ENV=%s for the local %q default, or NOTIFICATION_PROVIDER=%s)", AppEnvDevelopment, NotificationProviderFake, NotificationProviderFCM)
	default:
		return "", fmt.Errorf("unsupported NOTIFICATION_PROVIDER %q (%q with APP_ENV=%s, or %q)", provider, NotificationProviderFake, AppEnvDevelopment, NotificationProviderFCM)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return fallback
}

func getEnvInt32(key string, fallback int32) int32 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return int32(n)
		}
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}

func splitCSV(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
