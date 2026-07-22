package service

import (
	"context"
	"errors"
	"testing"
)

type fakePinger struct {
	err error
}

func (f fakePinger) Ping(ctx context.Context) error {
	return f.err
}

func TestHealthService_Ready(t *testing.T) {
	svc := NewHealthService(fakePinger{})
	if err := svc.Ready(context.Background()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}

func TestHealthService_Ready_PropagatesError(t *testing.T) {
	wantErr := errors.New("db unreachable")
	svc := NewHealthService(fakePinger{err: wantErr})

	if err := svc.Ready(context.Background()); !errors.Is(err, wantErr) {
		t.Fatalf("expected %v, got %v", wantErr, err)
	}
}
