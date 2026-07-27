package service

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ObjectStore persists an already-validated media object under an
// opaque key and reports back the url a client reads it from. Hidden
// behind this interface (issue #70, mirroring service.SmsSender/
// OTP_PROVIDER — see docs/architecture/backend.md) so a real s3-compatible
// provider (digitalocean spaces is the mvp-selected target, see
// docs/architecture/backend.md) can be added later without touching
// MediaService, CatsService, or their tests. Put must not be called twice
// for the same key with different contents — callers generate a fresh key
// per object.
type ObjectStore interface {
	Put(ctx context.Context, key, contentType string, data []byte) (url string, err error)
	// Delete removes the object at key. Deleting an already-removed or
	// never-written key is not an error — it backs the "compensate a failed
	// db write by deleting the object just uploaded" path (see
	// MediaService.Upload/CatsService.Create), which must be safe to retry.
	Delete(ctx context.Context, key string) error
}

// objectKeyPattern is deliberately restrictive: a flat filename (uuid plus
// extension), never a nested path. This is what keeps FakeObjectStore's
// Delete and the GET /v1/media/objects/{key} read route safe against path
// traversal — a key can never contain "/" or "..".
var objectKeyPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// ErrInvalidObjectKey means a key isn't a safe flat filename — see
// objectKeyPattern.
var ErrInvalidObjectKey = errors.New("invalid object key")

func validateObjectKey(key string) error {
	if !objectKeyPattern.MatchString(key) || filepath.Base(key) != key {
		return ErrInvalidObjectKey
	}
	return nil
}

// FakeObjectStore is a deterministic, no-network ObjectStore for local
// development and automated/manual tests (the "test/fake object storage
// provider" issue #70 requires, matching FakeSmsSender's role for otp).
// Unlike FakeSmsSender it isn't purely a test double: it writes real files
// to dir, and MediaHandler.ServeObject reads them back, so a local manual
// walkthrough can actually view an uploaded photo end to end without any
// real object-storage account.
//
// This must never be wired in a production deployment — see
// docs/architecture/backend.md's OBJECT_STORAGE_PROVIDER config.
type FakeObjectStore struct {
	dir           string
	publicBaseURL string
}

// NewFakeObjectStore creates dir (and any missing parents) if needed and
// returns a store rooted there. publicBaseURL (e.g. "http://localhost:8080")
// is prepended to every url Put returns, so it's always absolute — a client
// can't resolve a host-relative path on its own — matching what a real
// s3-compatible provider would hand back natively.
func NewFakeObjectStore(dir, publicBaseURL string) (*FakeObjectStore, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("create media local dir: %w", err)
	}
	return &FakeObjectStore{dir: dir, publicBaseURL: strings.TrimRight(publicBaseURL, "/")}, nil
}

// Put writes data to dir/key and returns the local, controlled-read-delivery
// url MediaHandler.ServeObject answers (never a permanent public-write
// object url — see docs/architecture/api.md).
func (f *FakeObjectStore) Put(_ context.Context, key, _ string, data []byte) (string, error) {
	if err := validateObjectKey(key); err != nil {
		return "", err
	}
	path := filepath.Join(f.dir, key)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return "", fmt.Errorf("write media object: %w", err)
	}
	return f.publicBaseURL + "/v1/media/objects/" + key, nil
}

// Delete removes dir/key. A missing file is not an error — see the
// ObjectStore.Delete contract.
func (f *FakeObjectStore) Delete(_ context.Context, key string) error {
	if err := validateObjectKey(key); err != nil {
		return err
	}
	err := os.Remove(filepath.Join(f.dir, key))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("delete media object: %w", err)
	}
	return nil
}

// Get reads back the bytes written to dir/key by Put. Only the fake/local
// provider ever needs this — a real s3-compatible provider serves reads
// directly from its own public/signed urls, never proxied back through
// this api (see handler.MediaServeHandler, the "/v1/media/objects/{key}"
// route this backs).
func (f *FakeObjectStore) Get(_ context.Context, key string) ([]byte, error) {
	if err := validateObjectKey(key); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(f.dir, key))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrObjectNotFound
		}
		return nil, fmt.Errorf("read media object: %w", err)
	}
	return data, nil
}

// ErrObjectNotFound means no object exists at the requested key.
var ErrObjectNotFound = errors.New("object not found")
