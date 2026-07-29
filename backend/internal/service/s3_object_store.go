package service

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

const (
	// s3DefaultTimeout bounds one outbound attempt. Derived from the
	// incoming request's context, so a cancelled client request cancels
	// the outbound call too. Larger than twilioDefaultTimeout: a put
	// carries up to MEDIA_MAX_BYTES of body.
	s3DefaultTimeout = 30 * time.Second
	// s3RetryDelay separates the single retry from the failed attempt.
	s3RetryDelay = 250 * time.Millisecond
	// s3MaxResponseBytes caps how much of a response body is ever read —
	// bodies are only drained (for connection reuse), never parsed or
	// logged.
	s3MaxResponseBytes = 1 << 20
	// s3CacheControl is stamped on every stored object. Object keys are
	// fresh and random per upload (see mediaPipeline.upload) and an object
	// is never rewritten under the same key, so the longest practical
	// immutable policy is safe and lets the public endpoint/cdn cache hard.
	s3CacheControl = "public, max-age=31536000, immutable"
)

// S3ObjectStore is the s3-compatible implementation of ObjectStore (issue
// #89): Put uploads an object with PutObject, Delete removes it with
// DeleteObject, both signed with aws signature v4. Digitalocean spaces is
// the 0.1 deployment target, but nothing here is spaces-specific — any
// standard s3-style endpoint works. Signing is implemented locally over
// net/http rather than pulling in an aws sdk, matching how TwilioVerifier
// and FCMNotificationSender wrap their vendors.
//
// Objects are written with x-amz-acl: public-read (cat photos are public
// product content — docs/product/privacy.md) plus the exact content type
// the media pipeline validated and an immutable cache-control policy. Put
// returns publicBaseURL/key — the stable public read url — never the api
// endpoint used for writes.
//
// Failure handling is fail-closed and bounded: at most one retry, and only
// for transient failures (a 5xx response, 429 throttling, a dial error, or
// a per-attempt timeout). Unlike TwilioVerifier, a timed-out attempt is
// safe to repeat here: PutObject with the same key and bytes and
// DeleteObject are both idempotent, so the retry can never duplicate or
// corrupt anything. Nothing sensitive is ever logged: no keys (access or
// object), signatures, urls, or response bodies — only coarse outcome
// fields.
type S3ObjectStore struct {
	client          *http.Client
	logger          *slog.Logger
	endpoint        *url.URL
	region          string
	bucket          string
	accessKeyID     string
	secretAccessKey string
	publicBaseURL   string
	forcePathStyle  bool
	timeout         time.Duration
	retryDelay      time.Duration
	now             func() time.Time
}

// S3ObjectStoreOption configures optional S3ObjectStore behavior.
type S3ObjectStoreOption func(*S3ObjectStore)

// WithS3ForcePathStyle switches request and canonical urls from
// virtual-host style (bucket.endpoint-host/key) to path style
// (endpoint-host/bucket/key) — tests use it to address a local fake s3
// server that has no bucket subdomain, and it covers the rare compatible
// endpoint that needs it.
func WithS3ForcePathStyle() S3ObjectStoreOption {
	return func(s *S3ObjectStore) { s.forcePathStyle = true }
}

// WithS3Timeout overrides the per-attempt request timeout.
func WithS3Timeout(d time.Duration) S3ObjectStoreOption {
	return func(s *S3ObjectStore) { s.timeout = d }
}

// WithS3RetryDelay overrides the delay before the single retry — tests
// set it to zero.
func WithS3RetryDelay(d time.Duration) S3ObjectStoreOption {
	return func(s *S3ObjectStore) { s.retryDelay = d }
}

// WithS3Logger overrides the logger — tests use it to assert redaction.
func WithS3Logger(l *slog.Logger) S3ObjectStoreOption {
	return func(s *S3ObjectStore) { s.logger = l }
}

// NewS3ObjectStore validates that every required setting is present and
// well-formed — selecting s3 with an incomplete configuration must fail
// startup, not degrade at runtime (issue #89). Errors name the offending
// variable but never echo a configured secret value.
func NewS3ObjectStore(endpoint, region, bucket, accessKeyID, secretAccessKey, publicBaseURL string, opts ...S3ObjectStoreOption) (*S3ObjectStore, error) {
	var missing []string
	if endpoint == "" {
		missing = append(missing, "S3_ENDPOINT")
	}
	if region == "" {
		missing = append(missing, "S3_REGION")
	}
	if bucket == "" {
		missing = append(missing, "S3_BUCKET")
	}
	if accessKeyID == "" {
		missing = append(missing, "S3_ACCESS_KEY_ID")
	}
	if secretAccessKey == "" {
		missing = append(missing, "S3_SECRET_ACCESS_KEY")
	}
	if publicBaseURL == "" {
		missing = append(missing, "S3_PUBLIC_BASE_URL")
	}
	if len(missing) > 0 {
		return nil, errors.New("s3 object storage: missing required settings: " + strings.Join(missing, ", "))
	}

	parsedEndpoint, err := url.Parse(endpoint)
	if err != nil || parsedEndpoint.Scheme == "" || parsedEndpoint.Host == "" {
		return nil, errors.New("s3 object storage: S3_ENDPOINT must be an absolute url (scheme and host)")
	}
	parsedPublic, err := url.Parse(publicBaseURL)
	if err != nil || parsedPublic.Scheme == "" || parsedPublic.Host == "" {
		return nil, errors.New("s3 object storage: S3_PUBLIC_BASE_URL must be an absolute url (scheme and host)")
	}

	s := &S3ObjectStore{
		client:          &http.Client{},
		logger:          slog.Default(),
		endpoint:        parsedEndpoint,
		region:          region,
		bucket:          bucket,
		accessKeyID:     accessKeyID,
		secretAccessKey: secretAccessKey,
		publicBaseURL:   strings.TrimRight(publicBaseURL, "/"),
		timeout:         s3DefaultTimeout,
		retryDelay:      s3RetryDelay,
		now:             time.Now,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s, nil
}

// Put uploads data under key with the validated content type, the public
// acl, and the immutable cache policy, and returns the stable public read
// url. See the ObjectStore contract — callers never reuse a key.
func (s *S3ObjectStore) Put(ctx context.Context, key, contentType string, data []byte) (string, error) {
	if err := validateObjectKey(key); err != nil {
		return "", err
	}
	extraHeaders := map[string]string{
		"content-type":  contentType,
		"cache-control": s3CacheControl,
		"x-amz-acl":     "public-read",
	}
	status, err := s.do(ctx, "put", http.MethodPut, key, data, extraHeaders)
	if err != nil {
		return "", err
	}
	if status/100 != 2 {
		return "", s.classifyFailure("put", status)
	}
	return s.publicBaseURL + "/" + key, nil
}

// Delete removes the object at key. A 404 is success, not an error — see
// the ObjectStore.Delete contract's compensate-and-retry requirement.
func (s *S3ObjectStore) Delete(ctx context.Context, key string) error {
	if err := validateObjectKey(key); err != nil {
		return err
	}
	status, err := s.do(ctx, "delete", http.MethodDelete, key, nil, nil)
	if err != nil {
		return err
	}
	if status/100 == 2 || status == http.StatusNotFound {
		return nil
	}
	return s.classifyFailure("delete", status)
}

// classifyFailure maps a non-success status onto a returned error and the
// one log line allowed for it. Statuses are safe to surface; object keys,
// urls, and response bodies are not, so none of them appear in either.
func (s *S3ObjectStore) classifyFailure(op string, status int) error {
	switch status {
	case http.StatusUnauthorized, http.StatusForbidden:
		s.logger.Error("s3 object storage rejected the configured credentials", "op", op, "http_status", status)
	case http.StatusNotFound:
		// only reachable from Put: the bucket (or endpoint path) doesn't
		// exist — a configuration problem, not a transient outage.
		s.logger.Error("s3 object storage bucket not found — check S3_BUCKET and S3_ENDPOINT", "op", op, "http_status", status)
	default:
		s.logger.Warn("s3 object storage request failed", "op", op, "http_status", status)
	}
	return fmt.Errorf("s3 object storage: %s failed (http %d)", op, status)
}

// do runs one signed request with at most one retry. Retry happens only
// for failures that are transient and safe to repeat against idempotent
// PutObject/DeleteObject calls: a 5xx response, 429 throttling, a dial
// error, or a per-attempt timeout (safe here, unlike TwilioVerifier's
// never-retry-a-timeout rule — repeating an identical put or delete cannot
// duplicate anything). Cancellation of the incoming ctx always wins
// immediately. Transport errors are never logged verbatim: a *url.Error's
// message embeds the full request url, which contains the object key.
func (s *S3ObjectStore) do(ctx context.Context, op, method, key string, body []byte, extraHeaders map[string]string) (int, error) {
	const maxAttempts = 2
	for attempt := 1; ; attempt++ {
		status, err := s.doOnce(ctx, method, key, body, extraHeaders)
		retryable := (err == nil && (status >= 500 || status == http.StatusTooManyRequests)) || (err != nil && ctx.Err() == nil)
		if !retryable {
			if err != nil {
				if ctx.Err() != nil {
					return 0, ctx.Err()
				}
				s.logger.Warn("s3 object storage request failed", "op", op, "attempt", attempt, "error_kind", errorKind(err))
				return 0, fmt.Errorf("s3 object storage: %s failed (%s)", op, errorKind(err))
			}
			return status, nil
		}
		if attempt >= maxAttempts {
			if err != nil {
				s.logger.Warn("s3 object storage unavailable after retry", "op", op, "error_kind", errorKind(err))
				return 0, fmt.Errorf("s3 object storage: %s failed (%s)", op, errorKind(err))
			}
			return status, nil
		}
		if s.retryDelay > 0 {
			timer := time.NewTimer(s.retryDelay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return 0, ctx.Err()
			case <-timer.C:
			}
		}
	}
}

func (s *S3ObjectStore) doOnce(ctx context.Context, method, key string, body []byte, extraHeaders map[string]string) (int, error) {
	reqCtx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	requestURL, canonicalURI := s.objectURL(key)
	req, err := http.NewRequestWithContext(reqCtx, method, requestURL, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	for name, value := range extraHeaders {
		req.Header.Set(name, value)
	}
	s.sign(req, canonicalURI, body)

	resp, err := s.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	// drained for connection reuse only — never parsed, logged, or
	// surfaced (an error body could echo the signed request back).
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, s3MaxResponseBytes))
	return resp.StatusCode, nil
}

// objectURL builds the request url and the canonical uri sigv4 signs.
// Virtual-host style (bucket.endpoint-host/key) is the default every
// mainstream s3-compatible endpoint (including digitalocean spaces)
// supports; path style (endpoint-host/bucket/key) is opt-in via
// S3_FORCE_PATH_STYLE. Keys are flat validated filenames (see
// objectKeyPattern), so no per-segment uri escaping is needed.
func (s *S3ObjectStore) objectURL(key string) (requestURL, canonicalURI string) {
	if s.forcePathStyle {
		return s.endpoint.Scheme + "://" + s.endpoint.Host + "/" + s.bucket + "/" + key, "/" + s.bucket + "/" + key
	}
	return s.endpoint.Scheme + "://" + s.bucket + "." + s.endpoint.Host + "/" + key, "/" + key
}

// sign adds the aws signature v4 headers for a single-chunk request: the
// payload hash, the timestamp, and the Authorization header over every
// header this adapter sends. The signing key derivation and canonical
// formats follow the sigv4 specification for the "s3" service.
func (s *S3ObjectStore) sign(req *http.Request, canonicalURI string, body []byte) {
	now := s.now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")

	payloadHash := sha256Hex(body)
	req.Header.Set("x-amz-content-sha256", payloadHash)
	req.Header.Set("x-amz-date", amzDate)

	// canonical headers: every header we send, plus host, lowercased and
	// sorted. req.Host (not a Host header entry) is what the transport
	// actually sends.
	headers := map[string]string{"host": req.Host}
	if req.Host == "" {
		headers["host"] = req.URL.Host
	}
	for name := range req.Header {
		headers[strings.ToLower(name)] = strings.TrimSpace(req.Header.Get(name))
	}
	names := make([]string, 0, len(headers))
	for name := range headers {
		names = append(names, name)
	}
	sort.Strings(names)

	var canonicalHeaders strings.Builder
	for _, name := range names {
		canonicalHeaders.WriteString(name + ":" + headers[name] + "\n")
	}
	signedHeaders := strings.Join(names, ";")

	canonicalRequest := strings.Join([]string{
		req.Method,
		canonicalURI,
		"", // canonical query string — object put/delete send none
		canonicalHeaders.String(),
		signedHeaders,
		payloadHash,
	}, "\n")

	scope := dateStamp + "/" + s.region + "/s3/aws4_request"
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		sha256Hex([]byte(canonicalRequest)),
	}, "\n")

	signingKey := hmacSHA256(
		hmacSHA256(
			hmacSHA256(
				hmacSHA256([]byte("AWS4"+s.secretAccessKey), dateStamp),
				s.region),
			"s3"),
		"aws4_request")
	signature := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))

	req.Header.Set("Authorization",
		"AWS4-HMAC-SHA256 Credential="+s.accessKeyID+"/"+scope+
			", SignedHeaders="+signedHeaders+
			", Signature="+signature)
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, data string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data))
	return mac.Sum(nil)
}
