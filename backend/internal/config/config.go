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
	}

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
