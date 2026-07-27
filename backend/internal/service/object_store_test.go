package service

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestFakeObjectStore_PutGetDelete(t *testing.T) {
	dir := t.TempDir()
	store, err := NewFakeObjectStore(dir, "http://localhost:8080")
	if err != nil {
		t.Fatalf("NewFakeObjectStore: %v", err)
	}

	url, err := store.Put(context.Background(), "abc123.jpg", "image/jpeg", []byte("fake-jpeg-bytes"))
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	if url != "http://localhost:8080/v1/media/objects/abc123.jpg" {
		t.Errorf("unexpected url: %q", url)
	}

	if _, err := os.Stat(filepath.Join(dir, "abc123.jpg")); err != nil {
		t.Fatalf("expected file to exist on disk: %v", err)
	}

	data, err := store.Get(context.Background(), "abc123.jpg")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(data) != "fake-jpeg-bytes" {
		t.Errorf("unexpected data: %q", data)
	}

	if err := store.Delete(context.Background(), "abc123.jpg"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := store.Get(context.Background(), "abc123.jpg"); !errors.Is(err, ErrObjectNotFound) {
		t.Errorf("expected ErrObjectNotFound after delete, got %v", err)
	}
}

func TestFakeObjectStore_PutTrimsTrailingSlashFromBaseURL(t *testing.T) {
	store, err := NewFakeObjectStore(t.TempDir(), "http://localhost:8080/")
	if err != nil {
		t.Fatalf("NewFakeObjectStore: %v", err)
	}

	url, err := store.Put(context.Background(), "abc123.jpg", "image/jpeg", []byte("x"))
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	if url != "http://localhost:8080/v1/media/objects/abc123.jpg" {
		t.Errorf("unexpected url: %q", url)
	}
}

func TestFakeObjectStore_DeleteMissingIsNoop(t *testing.T) {
	store, err := NewFakeObjectStore(t.TempDir(), "http://localhost:8080")
	if err != nil {
		t.Fatalf("NewFakeObjectStore: %v", err)
	}
	if err := store.Delete(context.Background(), "never-written.jpg"); err != nil {
		t.Errorf("expected deleting a missing key to be a no-op, got %v", err)
	}
}

func TestFakeObjectStore_GetMissingReturnsErrObjectNotFound(t *testing.T) {
	store, err := NewFakeObjectStore(t.TempDir(), "http://localhost:8080")
	if err != nil {
		t.Fatalf("NewFakeObjectStore: %v", err)
	}
	if _, err := store.Get(context.Background(), "never-written.jpg"); !errors.Is(err, ErrObjectNotFound) {
		t.Errorf("expected ErrObjectNotFound, got %v", err)
	}
}

// TestFakeObjectStore_RejectsPathTraversal is the key security property of
// FakeObjectStore/objectKeyPattern: a key must never escape dir, since
// GET /v1/media/objects/{key} passes a caller-supplied path segment
// straight through to this store.
func TestFakeObjectStore_RejectsPathTraversal(t *testing.T) {
	dir := t.TempDir()
	store, err := NewFakeObjectStore(dir, "http://localhost:8080")
	if err != nil {
		t.Fatalf("NewFakeObjectStore: %v", err)
	}

	maliciousKeys := []string{
		"../../../etc/passwd",
		"../secret.txt",
		"a/../../b.jpg",
		"/etc/passwd",
		"nested/path.jpg",
		"",
	}
	for _, key := range maliciousKeys {
		if _, err := store.Put(context.Background(), key, "image/jpeg", []byte("x")); !errors.Is(err, ErrInvalidObjectKey) {
			t.Errorf("Put(%q): expected ErrInvalidObjectKey, got %v", key, err)
		}
		if _, err := store.Get(context.Background(), key); !errors.Is(err, ErrInvalidObjectKey) {
			t.Errorf("Get(%q): expected ErrInvalidObjectKey, got %v", key, err)
		}
		if err := store.Delete(context.Background(), key); !errors.Is(err, ErrInvalidObjectKey) {
			t.Errorf("Delete(%q): expected ErrInvalidObjectKey, got %v", key, err)
		}
	}
}
