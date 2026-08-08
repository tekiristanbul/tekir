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

// ObjectStorageProvider values ResolveObjectStorageProvider can return.
const (
	ObjectStorageProviderFake = "fake"
	ObjectStorageProviderS3   = "s3"
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

	// OTPReviewTestNumbers/OTPReviewTestCode configure an app-review otp
	// bypass (issue #184): apple review can't reliably receive a real sms on
	// a reviewer-controlled number, so a short allowlist of e.164 numbers
	// (OTP_REVIEW_TEST_NUMBERS, comma-separated) gets a fixed code
	// (OTP_REVIEW_TEST_CODE) instead of a real twilio verify round trip.
	// Raw values only — the fail-closed validation and parsing live in
	// ResolveOTPReviewAllowlist, which cmd/api calls at startup. Unset is
	// simply off; there is no path from this to a global bypass.
	OTPReviewTestNumbers string
	OTPReviewTestCode    string

	// ObjectStorageProvider selects the ObjectStore implementation for
	// media uploads: "fake" (a deterministic, local-disk provider — issue
	// #70) or "s3" (an s3-compatible provider; digitalocean spaces is the
	// 0.1 deployment target — issue #89). Raw environment value; the
	// environment-aware defaulting and validation live in
	// ResolveObjectStorageProvider, which cmd/api calls at startup —
	// exactly the OTPProvider/ResolveOTPProvider split (issue #59). "fake"
	// is only ever a default under an explicit APP_ENV=development;
	// production fails closed on unset/unknown/incomplete configuration.
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
	// MediaVideoMaxBytes is the equivalent cap for a video upload (issue
	// #153) — kept separate from MediaMaxBytes because a video isn't
	// re-encoded down like an image is, so it needs materially more
	// headroom for the same 30-second product cap to be reachable at all.
	MediaVideoMaxBytes int

	// S3Endpoint/S3Region/S3Bucket/S3AccessKeyID/S3SecretAccessKey/
	// S3PublicBaseURL configure the s3-compatible object-store adapter and
	// are required when ObjectStorageProvider is "s3" (issue #89). The names
	// are deliberately application-owned (S3_*, not AWS_*) so the process
	// can never accidentally pick up unrelated host credentials. Key values
	// are deployment secrets — never logged or echoed in errors.
	// S3PublicBaseURL is what read urls are built from (bucket public
	// endpoint or cdn), independent of the api endpoint used for writes.
	S3Endpoint        string
	S3Region          string
	S3Bucket          string
	S3AccessKeyID     string
	S3SecretAccessKey string
	S3PublicBaseURL   string
	// S3ForcePathStyle switches object urls from virtual-host style
	// (bucket.endpoint-host) to path style (endpoint-host/bucket) for the
	// rare s3-compatible endpoint that needs it. Digitalocean spaces does
	// not — leave it false there.
	S3ForcePathStyle bool

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
		OTPReviewTestNumbers:   os.Getenv("OTP_REVIEW_TEST_NUMBERS"),
		OTPReviewTestCode:      os.Getenv("OTP_REVIEW_TEST_CODE"),

		// raw value only — ResolveObjectStorageProvider applies the
		// environment-aware default and validation (issue #89). The old
		// unconditional "fake" default is gone: fake is only ever a default
		// under an explicit APP_ENV=development, so a production deployment
		// that forgets this variable fails startup instead of silently
		// writing media to local disk.
		ObjectStorageProvider: os.Getenv("OBJECT_STORAGE_PROVIDER"),
		MediaLocalDir:         getEnv("MEDIA_LOCAL_DIR", "./data/media"),
		MediaMaxBytes:         getEnvInt("MEDIA_MAX_BYTES", 8*1024*1024),
		MediaVideoMaxBytes:    getEnvInt("MEDIA_VIDEO_MAX_BYTES", 40*1024*1024),

		S3Endpoint:        os.Getenv("S3_ENDPOINT"),
		S3Region:          os.Getenv("S3_REGION"),
		S3Bucket:          os.Getenv("S3_BUCKET"),
		S3AccessKeyID:     os.Getenv("S3_ACCESS_KEY_ID"),
		S3SecretAccessKey: os.Getenv("S3_SECRET_ACCESS_KEY"),
		S3PublicBaseURL:   os.Getenv("S3_PUBLIC_BASE_URL"),
		S3ForcePathStyle:  getEnvBool("S3_FORCE_PATH_STYLE", false),

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

// ResolveOTPReviewAllowlist parses and validates the app-review otp bypass
// (issue #184). It is fail-closed the same way ResolveOTPProvider is:
//
//   - both OTP_REVIEW_TEST_NUMBERS and OTP_REVIEW_TEST_CODE unset means the
//     feature is off — this is the only case that returns a nil list
//     without error.
//   - either one set without the other is a startup error: a half-configured
//     allowlist never silently degrades to "off" or to a global bypass.
//   - OTP_REVIEW_TEST_NUMBERS must contain at least one comma-separated
//     entry once trimmed.
//
// Per-number validity (each entry must parse as a phone number) is checked
// by NewReviewAllowlistOTPProvider, not here, since that's where the
// e.164 normalization it must match already lives.
func (c Config) ResolveOTPReviewAllowlist() ([]string, string, error) {
	numbersRaw := strings.TrimSpace(c.OTPReviewTestNumbers)
	code := c.OTPReviewTestCode

	switch {
	case numbersRaw == "" && code == "":
		return nil, "", nil
	case numbersRaw == "" || code == "":
		return nil, "", fmt.Errorf("OTP_REVIEW_TEST_NUMBERS and OTP_REVIEW_TEST_CODE must both be set, or both left unset")
	}

	numbers := splitCSV(numbersRaw)
	if len(numbers) == 0 {
		return nil, "", fmt.Errorf("OTP_REVIEW_TEST_NUMBERS must list at least one phone number")
	}
	return numbers, code, nil
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

// ResolveObjectStorageProvider decides which object-storage provider
// cmd/api runs with (issue #89) and validates the selection is complete —
// the same fail-closed shape as ResolveOTPProvider (issue #59) and
// ResolveNotificationProvider (issue #84):
//
//   - "fake" is only reachable under an explicit APP_ENV=development —
//     as the default when OBJECT_STORAGE_PROVIDER is unset, or when set
//     explicitly.
//   - any other environment (production, unset, or unrecognized) rejects
//     fake, unset, and unknown providers outright; only "s3" is accepted
//     there.
//   - "s3" additionally requires S3_ENDPOINT, S3_REGION, S3_BUCKET,
//     S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, and S3_PUBLIC_BASE_URL in
//     every environment; any missing one fails resolution, naming the
//     missing variables but never echoing a configured value.
//
// There is intentionally no path that degrades a selected or required s3
// provider to fake/local disk — misconfiguration stops startup instead.
func (c Config) ResolveObjectStorageProvider() (string, error) {
	dev := c.AppEnv == AppEnvDevelopment

	provider := c.ObjectStorageProvider
	if provider == "" && dev {
		provider = ObjectStorageProviderFake
	}

	switch provider {
	case ObjectStorageProviderFake:
		if !dev {
			return "", fmt.Errorf("OBJECT_STORAGE_PROVIDER %q is only allowed with APP_ENV=%s (production requires OBJECT_STORAGE_PROVIDER=%s)", provider, AppEnvDevelopment, ObjectStorageProviderS3)
		}
		return ObjectStorageProviderFake, nil
	case ObjectStorageProviderS3:
		var missing []string
		if c.S3Endpoint == "" {
			missing = append(missing, "S3_ENDPOINT")
		}
		if c.S3Region == "" {
			missing = append(missing, "S3_REGION")
		}
		if c.S3Bucket == "" {
			missing = append(missing, "S3_BUCKET")
		}
		if c.S3AccessKeyID == "" {
			missing = append(missing, "S3_ACCESS_KEY_ID")
		}
		if c.S3SecretAccessKey == "" {
			missing = append(missing, "S3_SECRET_ACCESS_KEY")
		}
		if c.S3PublicBaseURL == "" {
			missing = append(missing, "S3_PUBLIC_BASE_URL")
		}
		if len(missing) > 0 {
			return "", fmt.Errorf("OBJECT_STORAGE_PROVIDER=%s requires %s", ObjectStorageProviderS3, strings.Join(missing, ", "))
		}
		return ObjectStorageProviderS3, nil
	case "":
		return "", fmt.Errorf("OBJECT_STORAGE_PROVIDER is required (set APP_ENV=%s for the local %q default, or OBJECT_STORAGE_PROVIDER=%s)", AppEnvDevelopment, ObjectStorageProviderFake, ObjectStorageProviderS3)
	default:
		return "", fmt.Errorf("unsupported OBJECT_STORAGE_PROVIDER %q (%q with APP_ENV=%s, or %q)", provider, ObjectStorageProviderFake, AppEnvDevelopment, ObjectStorageProviderS3)
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

// getEnvBool treats an unparseable value as the fallback rather than an
// error, matching getEnvInt/getEnvDuration's lenient posture for
// non-secret tuning knobs.
func getEnvBool(key string, fallback bool) bool {
	if v := os.Getenv(key); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
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
