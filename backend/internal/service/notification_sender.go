package service

import (
	"context"
	"errors"
	"log/slog"
	"sync"
)

// ErrPushTokenInvalid means the provider permanently rejected the message's
// push token (unregistered installation, malformed token, or a token minted
// for a different sender). The dispatch loop retires the token on this error
// (issue #84) — retrying it would fail forever.
var ErrPushTokenInvalid = errors.New("push token invalid or unregistered")

// PushMessage is one needs-help notification addressed to one device
// installation. PushToken is the provider-level delivery address (an fcm
// registration token — issue #84); DeviceID identifies the installation for
// logging and token retirement. Neither the token nor any id here may ever
// appear in a public API response (issue #84's exposure constraint).
type PushMessage struct {
	DeviceID  string
	PushToken string
	CatID     string
	UpdateID  string
	Category  string
}

// NotificationSender delivers one needs-help notification to a device.
// Hidden behind this interface (issue #78) so the real push vendor (fcm —
// issue #84) stays swappable without touching NotificationService, its
// tests, or the worker that calls it — mirrors SmsSender's shape (issue
// #58). Implementations report a permanently rejected token as
// ErrPushTokenInvalid; any other error is treated as transient by the
// caller.
type NotificationSender interface {
	Send(ctx context.Context, msg PushMessage) error
}

// FakeNotificationSender is a deterministic, no-network NotificationSender
// for local development and automated tests (issue #78, mirroring
// FakeSmsSender). It never makes a network call. Every send is logged at
// info level and recorded in memory so a test or manual walkthrough can
// assert which device would have been notified for which update.
//
// This must never be wired in a production deployment — see
// config.ResolveNotificationProvider (issue #84): "fake" is only reachable
// under an explicit APP_ENV=development, never as a silent fallback.
type FakeNotificationSender struct {
	mu   sync.Mutex
	sent []PushMessage
}

func NewFakeNotificationSender() *FakeNotificationSender {
	return &FakeNotificationSender{}
}

func (f *FakeNotificationSender) Send(_ context.Context, msg PushMessage) error {
	f.mu.Lock()
	f.sent = append(f.sent, msg)
	f.mu.Unlock()

	// the push token is deliberately absent from the log line — even the
	// fake provider treats delivery addresses as secrets (issue #84).
	slog.Info("fake needs-help notification (dev/test provider — never a real push send)",
		"device_id", msg.DeviceID, "cat_id", msg.CatID, "update_id", msg.UpdateID, "category", msg.Category)
	return nil
}

// Sent returns every notification recorded so far, in send order.
func (f *FakeNotificationSender) Sent() []PushMessage {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]PushMessage(nil), f.sent...)
}
