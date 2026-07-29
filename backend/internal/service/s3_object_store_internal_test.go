package service

import "testing"

// TestS3ObjectStore_ObjectURLStyles pins the two addressing styles: the
// virtual-host default digitalocean spaces uses, and the path-style
// opt-in the local fake s3 test server needs. Internal because the
// external tests can only exercise path style — a vhost bucket subdomain
// of 127.0.0.1 doesn't resolve.
func TestS3ObjectStore_ObjectURLStyles(t *testing.T) {
	vhost, err := NewS3ObjectStore("https://fra1.example.com", "fra1", "tekir-media", "AKID", "secret", "https://tekir-media.fra1.example.com")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	requestURL, canonicalURI := vhost.objectURL("photo.jpg")
	if requestURL != "https://tekir-media.fra1.example.com/photo.jpg" {
		t.Errorf("unexpected virtual-host url: %q", requestURL)
	}
	if canonicalURI != "/photo.jpg" {
		t.Errorf("unexpected virtual-host canonical uri: %q", canonicalURI)
	}

	pathStyle, err := NewS3ObjectStore("https://fra1.example.com", "fra1", "tekir-media", "AKID", "secret", "https://tekir-media.fra1.example.com", WithS3ForcePathStyle())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	requestURL, canonicalURI = pathStyle.objectURL("photo.jpg")
	if requestURL != "https://fra1.example.com/tekir-media/photo.jpg" {
		t.Errorf("unexpected path-style url: %q", requestURL)
	}
	if canonicalURI != "/tekir-media/photo.jpg" {
		t.Errorf("unexpected path-style canonical uri: %q", canonicalURI)
	}
}
