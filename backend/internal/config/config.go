// Package config loads runtime configuration from the environment.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Port            string
	DatabaseURL     string
	LogLevel        string
	ShutdownTimeout time.Duration
	CORSOrigins     []string

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
	// OTPProvider selects the SmsSender implementation. Only "fake" (the
	// deterministic, no-network, log-only provider) is wired as of issue
	// #58 — see docs/architecture/backend.md.
	OTPProvider string

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
		OTPProvider:       getEnv("OTP_PROVIDER", "fake"),

		ObjectStorageProvider: getEnv("OBJECT_STORAGE_PROVIDER", "fake"),
		MediaLocalDir:         getEnv("MEDIA_LOCAL_DIR", "./data/media"),
		MediaMaxBytes:         getEnvInt("MEDIA_MAX_BYTES", 8*1024*1024),
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
