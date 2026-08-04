package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// issue #101: the combined flag model — "yardıma ihtiyacı var" as a boolean
// on the ordinary update write, combinable with statuses, category-free.

func TestCatsService_CreateOrdinaryUpdate_WithNeedsHelp(t *testing.T) {
	catID := uuid.New()
	userID := uuid.New()
	returnedID := uuid.New()
	fixedNow := time.Date(2026, 8, 1, 10, 0, 0, 0, time.UTC)
	var captured repository.CreateOrdinaryUpdateParams
	svc := NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:  &captured,
	}, WithClock(func() time.Time { return fixedNow }))

	note := "kabı bomboştu ve halsizdi"
	update, err := svc.CreateOrdinaryUpdate(context.Background(), catID.String(), userID.String(), "", nil, []string{"water_provided"}, true, &note)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	if !update.NeedsHelp {
		t.Error("expected needs_help true on the response")
	}
	if update.Kind != "needs_help" {
		t.Errorf("expected wire kind needs_help for a help-carrying update, got %q", update.Kind)
	}
	if len(update.Statuses) != 1 || update.Statuses[0] != "water_provided" {
		t.Errorf("expected the combined update to keep its statuses, got %v", update.Statuses)
	}
	if update.NeedsHelpCategory == nil || *update.NeedsHelpCategory != needsHelpCompatCategory {
		t.Errorf("expected compat category %q, got %v", needsHelpCompatCategory, update.NeedsHelpCategory)
	}
	if update.NeedsHelpCategoryLabel == nil || *update.NeedsHelpCategoryLabel != needsHelpCompatCategoryLabel {
		t.Errorf("expected compat label %q, got %v", needsHelpCompatCategoryLabel, update.NeedsHelpCategoryLabel)
	}
	wantExpires := fixedNow.Add(NeedsHelpExpiry)
	if update.NeedsHelpExpiresAt == nil || !update.NeedsHelpExpiresAt.Equal(wantExpires) {
		t.Errorf("expected expires_at %v, got %v", wantExpires, update.NeedsHelpExpiresAt)
	}
	if update.NeedsHelpActive == nil || !*update.NeedsHelpActive {
		t.Errorf("expected a fresh help mark to be active, got %v", update.NeedsHelpActive)
	}

	if !captured.NeedsHelp {
		t.Error("expected repository params to carry needs_help true")
	}
	if captured.NeedsHelpCategory.Valid {
		t.Errorf("the combined write path must never store a category, got %v", captured.NeedsHelpCategory)
	}
	if !captured.NeedsHelpExpiresAt.Time.Equal(wantExpires) {
		t.Errorf("expected repository expires_at %v, got %v", wantExpires, captured.NeedsHelpExpiresAt.Time)
	}
}

func TestCatsService_CreateOrdinaryUpdate_HelpOnlyNoStatuses(t *testing.T) {
	returnedID := uuid.New()
	svc := NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
	}, WithClock(time.Now))

	update, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", nil, nil, true, nil)
	if err != nil {
		t.Fatalf("expected a help-only update (no statuses, no note) to be valid, got %v", err)
	}
	if !update.NeedsHelp {
		t.Error("expected needs_help true")
	}
	if update.Statuses == nil || len(update.Statuses) != 0 {
		t.Errorf("expected non-nil empty statuses, got %v", update.Statuses)
	}
}

func TestCatsService_CreateOrdinaryUpdate_EmptyWithoutHelpStaysInvalid(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})
	if _, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", nil, nil, false, nil); !errors.Is(err, ErrInvalidStatuses) {
		t.Fatalf("expected ErrInvalidStatuses, got %v", err)
	}
}

func TestCatsService_NeedsHelpNoteCap(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})
	over := strings.Repeat("ğ", needsHelpNoteMaxChars+1)
	atCap := strings.Repeat("ğ", needsHelpNoteMaxChars)

	if _, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", nil, nil, true, &over); !errors.Is(err, ErrNoteTooLong) {
		t.Fatalf("expected ErrNoteTooLong on the combined write, got %v", err)
	}
	if _, err := svc.CreateNeedsHelpUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", "trapped", &over); !errors.Is(err, ErrNoteTooLong) {
		t.Fatalf("expected ErrNoteTooLong on the compat endpoint, got %v", err)
	}

	// exactly at the cap (counted in runes, not bytes) is fine.
	returnedID := uuid.New()
	svc = NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
	}, WithClock(time.Now))
	if _, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", nil, nil, true, &atCap); err != nil {
		t.Fatalf("expected a %d-rune note to be accepted, got %v", needsHelpNoteMaxChars, err)
	}

	// an ordinary (no-help) comment is deliberately not capped by this rule.
	if _, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", nil, []string{"seen"}, false, &over); err != nil {
		t.Fatalf("expected the cap to apply only to help notes, got %v", err)
	}
}

func TestCatsService_ListCatUpdates_FlagRowCompatServing(t *testing.T) {
	fixedNow := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	authorID := uuid.New()
	note := "akşam biri daha bakabilir mi?"
	svc := NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				// a post-#101 combined row: stored kind stays 'ordinary'.
				ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
				Kind:               "ordinary",
				NeedsHelp:          true,
				Comment:            pgtype.Text{String: note, Valid: true},
				CreatedAt:          pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
				Seq:                pgtype.Int8{Int64: 2, Valid: true},
				NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(71 * time.Hour), Valid: true},
				Statuses:           []string{"water_provided"},
				AuthorUserID:       pgtype.UUID{Bytes: authorID, Valid: true},
			},
		},
	}, WithClock(func() time.Time { return fixedNow }))

	page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0, authorID.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	item := page.Items[0]
	if item.Kind != "needs_help" {
		t.Errorf("expected wire kind needs_help, got %q", item.Kind)
	}
	if !item.NeedsHelp {
		t.Error("expected needs_help true")
	}
	if item.NeedsHelpCategory == nil || *item.NeedsHelpCategory != needsHelpCompatCategory {
		t.Errorf("expected compat category, got %v", item.NeedsHelpCategory)
	}
	if item.NeedsHelpActive == nil || !*item.NeedsHelpActive {
		t.Errorf("expected active help state, got %v", item.NeedsHelpActive)
	}
	if len(item.Statuses) != 1 || item.Statuses[0] != "water_provided" {
		t.Errorf("expected statuses preserved on the wire, got %v", item.Statuses)
	}
	// a post-#101 row (stored kind 'ordinary') is correctable by its author
	// — the affordance must surface even though the wire kind says
	// needs_help (0.1 clients hide it on their side; 0.2 clients use it to
	// offer mark removal).
	if !item.AuthorIsMe || item.CorrectionExpiresAt == nil {
		t.Errorf("expected the author's correction affordance, got authorIsMe=%v expiresAt=%v", item.AuthorIsMe, item.CorrectionExpiresAt)
	}
}

func TestCatsService_CorrectOwnUpdate_ClearNeedsHelp(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	userID := uuid.New()
	createdAt := time.Date(2026, 8, 1, 9, 0, 0, 0, time.UTC)
	var captured repository.CorrectOwnUpdateParams
	svc := NewCatsService(fakeCatsLister{
		correctRow: repository.CorrectOrdinaryUpdateRow{
			ID:        pgtype.UUID{Bytes: updateID, Valid: true},
			CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
			UpdatedAt: pgtype.Timestamptz{Time: createdAt.Add(time.Minute), Valid: true},
			NeedsHelp: false,
		},
		capturedCorrect: &captured,
	}, WithClock(func() time.Time { return createdAt.Add(time.Minute) }))

	update, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), userID.String(), []string{"seen"}, true, nil)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if !captured.ClearNeedsHelp {
		t.Error("expected repository params to carry ClearNeedsHelp")
	}
	if update.NeedsHelp || update.Kind != "ordinary" {
		t.Errorf("expected a cleared response, got needsHelp=%v kind=%q", update.NeedsHelp, update.Kind)
	}
	if update.NeedsHelpExpiresAt != nil || update.NeedsHelpActive != nil {
		t.Errorf("expected no help lifecycle after clearing, got %v/%v", update.NeedsHelpExpiresAt, update.NeedsHelpActive)
	}
}

func TestCatsService_CorrectOwnUpdate_HollowRequestRejected(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})
	// clearing the mark while also submitting no statuses would leave a
	// status-less, flag-less husk — rejected before any database work.
	if _, err := svc.CorrectOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), nil, true, nil); !errors.Is(err, ErrInvalidStatuses) {
		t.Fatalf("expected ErrInvalidStatuses, got %v", err)
	}
}

func TestCatsService_CorrectOwnUpdate_PostStateInvariantResolvesTo400(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	userID := uuid.New()
	createdAt := time.Date(2026, 8, 1, 9, 0, 0, 0, time.UTC)
	svc := NewCatsService(fakeCatsLister{
		correctErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			ID:           pgtype.UUID{Bytes: updateID, Valid: true},
			CatID:        pgtype.UUID{Bytes: catID, Valid: true},
			AuthorUserID: pgtype.UUID{Bytes: userID, Valid: true},
			Kind:         "ordinary",
			NeedsHelp:    false,
			CreatedAt:    pgtype.Timestamptz{Time: createdAt, Valid: true},
		},
	}, WithClock(func() time.Time { return createdAt.Add(time.Minute) }))

	// empty statuses without clearing is only valid when the row still has
	// its flag; this row doesn't, so the conditional statement affected no
	// rows and the disambiguation must land on invalid content, not 404.
	if _, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), userID.String(), nil, false, nil); !errors.Is(err, ErrInvalidStatuses) {
		t.Fatalf("expected ErrInvalidStatuses, got %v", err)
	}
}

func TestDeriveActiveAlert_CategoryLessServesCompatPairAndNote(t *testing.T) {
	fixedNow := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	clock := func() time.Time { return fixedNow }
	note := "sahilde, halsiz görünüyor"

	alert := deriveActiveAlert(clock,
		pgtype.Text{},
		pgtype.Text{String: note, Valid: true},
		pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
		pgtype.Timestamptz{Time: fixedNow.Add(time.Hour), Valid: true},
	)
	if alert == nil {
		t.Fatal("expected an active alert for a category-less help mark")
	}
	if alert.Category != needsHelpCompatCategory || alert.CategoryLabel != needsHelpCompatCategoryLabel {
		t.Errorf("expected compat pair, got %q/%q", alert.Category, alert.CategoryLabel)
	}
	if alert.Comment == nil || *alert.Comment != note {
		t.Errorf("expected the note on the alert, got %v", alert.Comment)
	}

	// expired: never active on a read, regardless of what a client's own
	// clock would say.
	if a := deriveActiveAlert(clock,
		pgtype.Text{},
		pgtype.Text{},
		pgtype.Timestamptz{Time: fixedNow.Add(-73 * time.Hour), Valid: true},
		pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
	); a != nil {
		t.Errorf("expected nil for an expired mark, got %+v", a)
	}

	// legacy row: stored category and its real label survive.
	if a := deriveActiveAlert(clock,
		pgtype.Text{String: "trapped", Valid: true},
		pgtype.Text{},
		pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
		pgtype.Timestamptz{Time: fixedNow.Add(time.Hour), Valid: true},
	); a == nil || a.Category != "trapped" || a.CategoryLabel != needsHelpCategoryLabels["trapped"] {
		t.Errorf("expected the stored legacy category served unchanged, got %+v", a)
	}
}
