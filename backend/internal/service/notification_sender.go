package service

import (
	"context"
	"log/slog"
	"sync"
)

// NotificationSender delivers one needs-help notification to a device.
// Hidden behind this interface (issue #78) so a real push vendor (fcm —
// see docs/architecture/backend.md) can be added later without touching
// NotificationService, its tests, or the worker that calls it — mirrors
// SmsSender's shape (issue #58).
type NotificationSender interface {
	Send(ctx context.Context, deviceID, catID, updateID, category string) error
}

// FakeNotificationSender is a deterministic, no-network NotificationSender
// for local development and automated tests (issue #78, mirroring
// FakeSmsSender). It never makes a network call. Every send is logged at
// info level and recorded in memory so a test or manual walkthrough can
// assert which device would have been notified for which update.
//
// This must never be wired in a production deployment — see cmd/notifier's
// newNotificationSender, which only ever selects "fake" today and fails
// startup on any other NOTIFICATION_PROVIDER value rather than silently
// falling back to this.
type FakeNotificationSender struct {
	mu   sync.Mutex
	sent []FakeSentNotification
}

// FakeSentNotification is one recorded call to FakeNotificationSender.Send.
type FakeSentNotification struct {
	DeviceID string
	CatID    string
	UpdateID string
	Category string
}

func NewFakeNotificationSender() *FakeNotificationSender {
	return &FakeNotificationSender{}
}

func (f *FakeNotificationSender) Send(_ context.Context, deviceID, catID, updateID, category string) error {
	f.mu.Lock()
	f.sent = append(f.sent, FakeSentNotification{DeviceID: deviceID, CatID: catID, UpdateID: updateID, Category: category})
	f.mu.Unlock()

	slog.Info("fake needs-help notification (dev/test provider — never a real push send)",
		"device_id", deviceID, "cat_id", catID, "update_id", updateID, "category", category)
	return nil
}

// Sent returns every notification recorded so far, in send order.
func (f *FakeNotificationSender) Sent() []FakeSentNotification {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]FakeSentNotification(nil), f.sent...)
}
