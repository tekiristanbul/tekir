package service_test

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

const (
	testS3Region = "fra1"
	testS3Bucket = "test-bucket"
	testS3Access = "TESTACCESSKEYID"
	testS3Secret = "test-secret-access-key-value"
	testS3Public = "https://test-bucket.fra1.example.com"
)

// newTestS3Store points an adapter at a local fake s3 server. Path style is
// forced because the fake server has no per-bucket subdomain to resolve.
func newTestS3Store(t *testing.T, endpoint string, opts ...service.S3ObjectStoreOption) *service.S3ObjectStore {
	t.Helper()
	opts = append([]service.S3ObjectStoreOption{
		service.WithS3ForcePathStyle(),
		service.WithS3RetryDelay(0),
	}, opts...)
	store, err := service.NewS3ObjectStore(endpoint, testS3Region, testS3Bucket, testS3Access, testS3Secret, testS3Public, opts...)
	if err != nil {
		t.Fatalf("unexpected constructor error: %v", err)
	}
	return store
}

// verifySigV4 recomputes the aws signature v4 of a received request with
// the known test secret and fails the test on any mismatch — proving the
// adapter signs exactly what it sends, not just that an Authorization
// header exists.
func verifySigV4(t *testing.T, r *http.Request, body []byte) {
	t.Helper()

	auth := r.Header.Get("Authorization")
	const prefix = "AWS4-HMAC-SHA256 Credential="
	if !strings.HasPrefix(auth, prefix) {
		t.Fatalf("unexpected authorization scheme: %q", auth)
	}
	var credential, signedHeaders, signature string
	for _, part := range strings.Split(auth[len("AWS4-HMAC-SHA256 "):], ", ") {
		switch {
		case strings.HasPrefix(part, "Credential="):
			credential = strings.TrimPrefix(part, "Credential=")
		case strings.HasPrefix(part, "SignedHeaders="):
			signedHeaders = strings.TrimPrefix(part, "SignedHeaders=")
		case strings.HasPrefix(part, "Signature="):
			signature = strings.TrimPrefix(part, "Signature=")
		}
	}

	credParts := strings.Split(credential, "/")
	if len(credParts) != 5 || credParts[0] != testS3Access || credParts[2] != testS3Region || credParts[3] != "s3" || credParts[4] != "aws4_request" {
		t.Fatalf("unexpected credential scope: %q", credential)
	}
	dateStamp := credParts[1]
	scope := strings.Join(credParts[1:], "/")

	payloadHash := r.Header.Get("x-amz-content-sha256")
	bodySum := sha256.Sum256(body)
	if payloadHash != hex.EncodeToString(bodySum[:]) {
		t.Fatalf("x-amz-content-sha256 %q does not match the request body", payloadHash)
	}

	names := strings.Split(signedHeaders, ";")
	if !sort.StringsAreSorted(names) {
		t.Fatalf("signed headers are not sorted: %q", signedHeaders)
	}
	var canonicalHeaders strings.Builder
	for _, name := range names {
		value := r.Header.Get(name)
		if name == "host" {
			value = r.Host
		}
		canonicalHeaders.WriteString(name + ":" + strings.TrimSpace(value) + "\n")
	}

	canonicalRequest := strings.Join([]string{
		r.Method,
		r.URL.EscapedPath(),
		r.URL.RawQuery,
		canonicalHeaders.String(),
		signedHeaders,
		payloadHash,
	}, "\n")
	crSum := sha256.Sum256([]byte(canonicalRequest))
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		r.Header.Get("x-amz-date"),
		scope,
		hex.EncodeToString(crSum[:]),
	}, "\n")

	mac := func(key []byte, data string) []byte {
		h := hmac.New(sha256.New, key)
		h.Write([]byte(data))
		return h.Sum(nil)
	}
	signingKey := mac(mac(mac(mac([]byte("AWS4"+testS3Secret), dateStamp), testS3Region), "s3"), "aws4_request")
	expected := hex.EncodeToString(mac(signingKey, stringToSign))
	if signature != expected {
		t.Fatalf("signature mismatch: got %q, expected %q", signature, expected)
	}
}

func TestS3ObjectStore_PutStoresWithMetadataAndValidSignature(t *testing.T) {
	data := []byte("fake-jpeg-bytes")
	const key = "0d9c2f7e-media-test.jpg"

	var got struct {
		method, path, contentType, cacheControl, acl string
		body                                         []byte
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		got.method = r.Method
		got.path = r.URL.Path
		got.contentType = r.Header.Get("Content-Type")
		got.cacheControl = r.Header.Get("Cache-Control")
		got.acl = r.Header.Get("x-amz-acl")
		got.body = body
		verifySigV4(t, r, body)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	store := newTestS3Store(t, srv.URL)
	url, err := store.Put(context.Background(), key, "image/jpeg", data)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if url != testS3Public+"/"+key {
		t.Errorf("expected public url %q, got %q", testS3Public+"/"+key, url)
	}
	if got.method != http.MethodPut {
		t.Errorf("expected PUT, got %s", got.method)
	}
	if got.path != "/"+testS3Bucket+"/"+key {
		t.Errorf("expected path-style object path, got %q", got.path)
	}
	if got.contentType != "image/jpeg" {
		t.Errorf("expected validated content type to be sent, got %q", got.contentType)
	}
	if !strings.Contains(got.cacheControl, "immutable") || !strings.Contains(got.cacheControl, "public") {
		t.Errorf("expected a public immutable cache-control policy, got %q", got.cacheControl)
	}
	if got.acl != "public-read" {
		t.Errorf("expected x-amz-acl public-read, got %q", got.acl)
	}
	if !bytes.Equal(got.body, data) {
		t.Errorf("stored body does not match uploaded data")
	}
}

func TestS3ObjectStore_DeleteSuccess(t *testing.T) {
	const key = "delete-me.png"
	var got struct{ method, path string }
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.method = r.Method
		got.path = r.URL.Path
		verifySigV4(t, r, nil)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	store := newTestS3Store(t, srv.URL)
	if err := store.Delete(context.Background(), key); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.method != http.MethodDelete {
		t.Errorf("expected DELETE, got %s", got.method)
	}
	if got.path != "/"+testS3Bucket+"/"+key {
		t.Errorf("expected path-style object path, got %q", got.path)
	}
}

// TestS3ObjectStore_DeleteMissingIsNoop mirrors the fake store's contract:
// compensation deletes must be safe to repeat, so a 404 is success.
func TestS3ObjectStore_DeleteMissingIsNoop(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	store := newTestS3Store(t, srv.URL)
	if err := store.Delete(context.Background(), "never-existed.jpg"); err != nil {
		t.Fatalf("expected deleting a missing object to be a no-op, got %v", err)
	}
}

// TestS3ObjectStore_RetriesTransientFailures covers the bounded retry
// policy: one retry for 5xx and throttling responses, then success.
func TestS3ObjectStore_RetriesTransientFailures(t *testing.T) {
	for _, status := range []int{http.StatusInternalServerError, http.StatusServiceUnavailable, http.StatusTooManyRequests} {
		var attempts atomic.Int32
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			if attempts.Add(1) == 1 {
				w.WriteHeader(status)
				return
			}
			w.WriteHeader(http.StatusOK)
		}))

		store := newTestS3Store(t, srv.URL)
		_, err := store.Put(context.Background(), "retry.jpg", "image/jpeg", []byte("x"))
		if err != nil {
			t.Errorf("status %d: expected retry to succeed, got %v", status, err)
		}
		if got := attempts.Load(); got != 2 {
			t.Errorf("status %d: expected 2 attempts, got %d", status, got)
		}
		srv.Close()
	}
}

func TestS3ObjectStore_RetryIsBounded(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	store := newTestS3Store(t, srv.URL)
	if _, err := store.Put(context.Background(), "always-fails.jpg", "image/jpeg", []byte("x")); err == nil {
		t.Fatal("expected error after exhausted retries")
	}
	if got := attempts.Load(); got != 2 {
		t.Errorf("expected exactly 2 attempts, got %d", got)
	}
}

func TestS3ObjectStore_PermanentFailureNotRetried(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer srv.Close()

	store := newTestS3Store(t, srv.URL)
	if _, err := store.Put(context.Background(), "rejected.jpg", "image/jpeg", []byte("x")); err == nil {
		t.Fatal("expected error on permanent failure")
	}
	if got := attempts.Load(); got != 1 {
		t.Errorf("expected a single attempt, got %d", got)
	}
}

// TestS3ObjectStore_AuthFailureIsRedacted proves a credential rejection
// fails without retry and that neither the returned error nor the log
// output leaks the secret, the access key id, or the object key.
func TestS3ObjectStore_AuthFailureIsRedacted(t *testing.T) {
	const key = "secret-adjacent.jpg"
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()

	var logBuf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logBuf, nil))
	store := newTestS3Store(t, srv.URL, service.WithS3Logger(logger))

	_, err := store.Put(context.Background(), key, "image/jpeg", []byte("x"))
	if err == nil {
		t.Fatal("expected error on credential rejection")
	}
	if got := attempts.Load(); got != 1 {
		t.Errorf("expected a single attempt, got %d", got)
	}
	logged := logBuf.String()
	if logged == "" {
		t.Error("expected a credential-rejection log line")
	}
	for _, sensitive := range []string{testS3Secret, testS3Access, key} {
		if strings.Contains(logged, sensitive) {
			t.Errorf("log output leaks %q", sensitive)
		}
		if strings.Contains(err.Error(), sensitive) {
			t.Errorf("error leaks %q: %v", sensitive, err)
		}
	}
}

// TestS3ObjectStore_TimeoutRetried documents the deliberate divergence
// from TwilioVerifier: put/delete are idempotent, so a timed-out attempt
// is safe to repeat once.
func TestS3ObjectStore_TimeoutRetried(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		// a plain sleep, not a block on r.Context().Done(): with an unread
		// request body the server never observes the client's disconnect,
		// so a context-blocked handler deadlocks srv.Close().
		if attempts.Add(1) == 1 {
			time.Sleep(300 * time.Millisecond)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	store := newTestS3Store(t, srv.URL, service.WithS3Timeout(50*time.Millisecond))
	if _, err := store.Put(context.Background(), "slow-once.jpg", "image/jpeg", []byte("x")); err != nil {
		t.Fatalf("expected timed-out attempt to be retried successfully, got %v", err)
	}
	if got := attempts.Load(); got != 2 {
		t.Errorf("expected 2 attempts, got %d", got)
	}
}

func TestS3ObjectStore_CancellationWins(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		// bounded sleep instead of blocking on the request context — see
		// TestS3ObjectStore_TimeoutRetried's handler note.
		time.Sleep(500 * time.Millisecond)
	}))
	defer srv.Close()

	store := newTestS3Store(t, srv.URL)
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(50*time.Millisecond, cancel)

	_, err := store.Put(ctx, "cancelled.jpg", "image/jpeg", []byte("x"))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}

func TestS3ObjectStore_RejectsInvalidKeys(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		t.Error("no request may be sent for an invalid key")
	}))
	defer srv.Close()

	store := newTestS3Store(t, srv.URL)
	for _, key := range []string{"", "../evil", "a/b.jpg", ".hidden"} {
		if _, err := store.Put(context.Background(), key, "image/jpeg", []byte("x")); !errors.Is(err, service.ErrInvalidObjectKey) {
			t.Errorf("Put(%q): expected ErrInvalidObjectKey, got %v", key, err)
		}
		if err := store.Delete(context.Background(), key); !errors.Is(err, service.ErrInvalidObjectKey) {
			t.Errorf("Delete(%q): expected ErrInvalidObjectKey, got %v", key, err)
		}
	}
}

// TestNewS3ObjectStore_Validation covers startup validation: missing
// settings are named (never echoed) and malformed urls are rejected before
// the server ever accepts traffic.
func TestNewS3ObjectStore_Validation(t *testing.T) {
	_, err := service.NewS3ObjectStore("", "", "", "", "", "")
	if err == nil {
		t.Fatal("expected error for empty configuration")
	}
	for _, name := range []string{"S3_ENDPOINT", "S3_REGION", "S3_BUCKET", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "S3_PUBLIC_BASE_URL"} {
		if !strings.Contains(err.Error(), name) {
			t.Errorf("expected error to name %s, got %q", name, err)
		}
	}

	if _, err := service.NewS3ObjectStore("not-a-url", testS3Region, testS3Bucket, testS3Access, testS3Secret, testS3Public); err == nil {
		t.Error("expected error for a non-absolute endpoint")
	} else if strings.Contains(err.Error(), testS3Secret) {
		t.Errorf("error leaks the secret: %q", err)
	}
	if _, err := service.NewS3ObjectStore("https://fra1.example.com", testS3Region, testS3Bucket, testS3Access, testS3Secret, "objects.example.com"); err == nil {
		t.Error("expected error for a non-absolute public base url")
	}

	if _, err := service.NewS3ObjectStore("https://fra1.example.com", testS3Region, testS3Bucket, testS3Access, testS3Secret, testS3Public); err != nil {
		t.Errorf("expected a fully configured store to construct, got %v", err)
	}
}
