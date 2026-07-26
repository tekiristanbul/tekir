package service

import (
	"context"
	"log/slog"
	"sync"
)

// SmsSender delivers an otp code to a phone number. Hidden behind this
// interface (issue #58) so a real vendor — twilio is the mvp-selected
// provider, see docs/architecture/backend.md — can be added later without
// touching AuthService, its tests, or callers of RequestOTP.
type SmsSender interface {
	Send(ctx context.Context, phone, code string) error
}

// FakeSmsSender is a deterministic, no-network SmsSender for local
// development and automated tests — the "test/fake otp provider" issue
// #58 requires. It never makes a network call. Every send is logged at
// info level and recorded in memory so a local manual walkthrough or a
// test can retrieve the code that would have been delivered.
//
// This must never be wired in a production deployment: logging a
// verification code is only acceptable because this sender is exclusively
// the local/CI stand-in for a real provider (see docs/architecture/
// backend.md's OTP_PROVIDER config).
type FakeSmsSender struct {
	mu   sync.Mutex
	sent []FakeSentMessage
}

// FakeSentMessage is one recorded call to FakeSmsSender.Send.
type FakeSentMessage struct {
	Phone string
	Code  string
}

func NewFakeSmsSender() *FakeSmsSender {
	return &FakeSmsSender{}
}

func (f *FakeSmsSender) Send(_ context.Context, phone, code string) error {
	f.mu.Lock()
	f.sent = append(f.sent, FakeSentMessage{Phone: phone, Code: code})
	f.mu.Unlock()

	slog.Info("fake otp sms (dev/test provider — never a real send)", "phone", phone, "code", code)
	return nil
}

// LastCodeFor returns the most recently sent code for phone, and whether
// one exists.
func (f *FakeSmsSender) LastCodeFor(phone string) (string, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.sent) - 1; i >= 0; i-- {
		if f.sent[i].Phone == phone {
			return f.sent[i].Code, true
		}
	}
	return "", false
}
