# alerts

## goal

define how cats that need help get noticed.

## decisions — 0.1 (implemented)

product-owner decision on issue #4 (approved for mvp):

- "needs help" is represented as an update subtype, not a fully separate structure — it carries its own lifecycle fields (see [[updates]]). this also resolves the conflict [[principles]] used to flag: it's a special kind of update, not a separate alert type.
- the fixed mvp help-category vocabulary: injured/sick, food needed, water needed, unsafe location, trapped. **superseded in 0.2 — see below.**
- an alert expires automatically after a fixed 72 hours. this is intentional, to avoid clutter.
- creating a needs-help update requires authenticated bearer identity, consistent with the authentication requirement for every update recorded in [[trust]].
- there is no "resolve" action — the product's job ends at notifying followers. after 72 hours, the alert simply expires.
- notifications for an alert go to that cat's followers only (same mechanism as a regular update, see [[notifications]]).
- an active alert is emphasized on the map and cat detail; an expired alert stays in the cat's history without that emphasis.

## decisions — 0.2 simplified help contract (issue #100, product-owner decision on pr #103)

- help is one explicit state: a cat either needs help or it does not. there are no help subcategories — nothing like `mama gerekiyor`, `su gerekiyor`, or `veteriner gerekiyor` exists anywhere in the 0.2 experience.
- **`yardıma ihtiyacı var` is one of the options in the normal update screen**, side by side with `gördüm`, `mama verdim`, and `su verdim`. it is not a separate flow.
- a user may select multiple options in a single update — for example `su verdim` + `yardıma ihtiyacı var`. the update appears as **one event** on the timeline.
- when `yardıma ihtiyacı var` is selected, an optional free-text note can be added to explain the situation.
- an update carrying the help option opens the cat's active `yardıma ihtiyacı var` state.
- the active help state and its note are shown on the cat profile.
- **legacy help categories are never reproduced in the new interface** — not as labels, suggested or generated notes, or any other form.
- caretaker and moderator workflows are out of scope.
- copy and layout follow the approved cat-profile design at `docs/design/screens/cat-profile.html` (imported by this issue). its binding copy:
  - update-sheet toggle: `yardım`
  - notification banner in the sheet: `takipçilere bildirim gider`
  - note placeholder: `ne oldu? kısaca yaz — yardıma gelen anlasın`
  - submit button with help selected: `yardım çağrısıyla paylaş`
  - timeline chip on a help-bearing record: `yardım gerekiyor`
  - the design's own binding note: `mama` and `su` in the sheet record **work done** (`mama verildi`, `su verildi`), never a need category. the header strip shows what was last *done*, not what is needed.

## proposed decisions — pending product-owner approval

these answer the remaining questions issue #100 requires this contract to decide. none is implemented; each needs explicit product-owner approval recorded on the issue before #101/#102 start. (the issue's migration question is deliberately **not** decided here — see the open implementation questions below, per the product-owner decision on pr #103.)

1. **clearing authority: nobody.** 0.2 keeps the 0.1 rule — there is no manual clear or resolve action for anyone (author included); expiry is the only clearing mechanism. known consequence to weigh: a mistaken help mark notifies all followers immediately and stands for 72 hours (see unresolved decision 2 on the author correction window).
2. **expiry: unchanged.** a help state expires automatically exactly 72 hours after it is marked. an expired help record stays in the cat's history without active emphasis.
3. **note constraints.** the note is optional, free text, at most 500 unicode characters, trimmed, empty treated as absent. it is public user-generated content under the same visibility, retention, and account-deletion rules as update comments ([[privacy]]); it is never sent to the analytics provider and never included in a push payload. automated moderation is out of scope; existing admin/legal moderation obligations apply unchanged.
4. **notification wording: unchanged, already category-free.** push title/body stay `Yardım çağrısı` / `Takip ettiğin bir kedinin yardıma ihtiyacı var.`; the in-app row copy stays `Takip ettiğin bir kedi için yardım bildirimi`. the only 0.2 change is wire-level: the push data payload's `category` key is dropped. the trigger rule in [[notifications]] is unchanged in substance: only an update that carries the help option notifies, followers only; statuses alone never notify.
5. **analytics after the category enum retires.** `needs_help_created` remains the event name and loses its `needs_help_category` parameter — it carries no parameters. because one update can now carry both statuses and help, a combined update emits both events: `ordinary_update_created` (with its `update_status` parameter) when at least one status is present, and `needs_help_created` when the help option is set. the `needs_help_category` parameter vocabulary and the corresponding closed enum in `app/lib/core/analytics/analytics_events.dart` are removed in #102. the note is free text and therefore never collected ([[analytics]] "never collected" already covers this). unchanged: `auth_intent: needs_help`, `source: discover_needs_help`, `discover_view: needs_help`, and the discover api's `filter=needs_help` value.

### target api shape (0.2 — definition only; migration is #101, not this issue)

help folds into the existing update write as a flag; there is no separate help flow. the api field name for the note stays `comment` (the user-facing turkish term is "not") to avoid a needless wire rename.

```text
POST /v1/cats/{cat_id}/updates  (Bearer required)
  { statuses[]?, needs_help?, comment? }
  → 201 { id, statuses[], needs_help, comment|null, created_at,
          needs_help_expires_at|null, needs_help_active|null }

active_alert: { comment|null, created_at, expires_at, ... } | null
```

- at least one of a non-empty `statuses` or `needs_help: true` is required; a comment-only request stays invalid (unchanged rule from [[updates]]).
- `needs_help_expires_at` is server-computed (`created_at + 72h`) only when the flag is set; auth, transactional outbox enqueue, and the error taxonomy carry over from the implemented contract in [[api]].
- exact wire details — the fate of `POST /v1/cats/{cat_id}/needs-help`, the compatibility fields old clients need inside `active_alert` and timeline items, and the `kind` column's disposition — are open implementation questions below, finalized in #101.

## unresolved product decisions — must be answered before #101/#102

1. **re-marking while a help state is already active.** is selecting `yardıma ihtiyacı var` for an already-helping cat rejected, idempotent (no new window, no new notification), or does it restart the 72-hour window and notify again? this defines both the api semantics and the notification-spam surface.
2. **author correction window.** correction/deletion currently excludes needs-help records entirely (`404`). with help now an option on the normal update, does the 10-minute window apply to a help-carrying update, given a mistaken help mark notifies all followers with no undo? (interacts with proposed decision 1.)

## open implementation questions — for #101, deliberately not decided in this contract

the product-owner decision on pr #103 defers migration behavior out of this design contract. binding constraints from issue #100: existing category-bearing records must not be silently discarded, must remain interpretable during mixed 0.1/0.2 client operation, and the path must be reversible. within those constraints, #101 must answer:

- how existing `kind = 'needs_help'` rows (category-bearing, status-less) are represented in the combined model, and what happens to the stored `needs_help_category` values — noting the 0.2 ui rule above: legacy categories are never reproduced in the new interface, in any form.
- mixed-client wire compatibility: 0.1 clients require non-null `category`/`category_label` wherever an alert appears; how responses satisfy them for records created after the migration.
- whether `POST /v1/cats/{cat_id}/needs-help` is retired immediately or kept serving during the transition.
- the `updates.kind` column, `updates_kind_fields_ck` constraint, and index rework for the flag model.
- moving the notification fan-out trigger from `kind = 'needs_help'` to the help flag, and dropping the push data payload's `category` key.

## affected documents and contracts (0.2 blast radius)

product/design docs (updated or superseded by this contract): `docs/product/alerts.md` (this file), `docs/product/updates.md`, `docs/product/map.md`, `docs/product/analytics.md`, `docs/product/notifications.md`, `docs/design/implementation-contract.md`, `docs/design/screens/cat-profile.html` (imported reference).

contracts to change in #101 (api/backend) and #102 (flutter) — no code changes in this issue:

- `docs/architecture/api.md` — `active_alert` shape, update/needs-help write contracts, category vocabulary paragraphs.
- `docs/architecture/db.md` + schema — `updates.kind`, `updates.needs_help_category`, `updates_kind_fields_ck`, indexes.
- backend: `internal/service/cats.go` (`CreateOrdinaryUpdate`/`CreateNeedsHelpUpdate`), `internal/handler/cats.go`, `internal/service/notifications.go` + `notification_sender.go` + `fcm_notification_sender.go` (push data `category` key), seed data.
- flutter: `app/lib/features/needs_help/` (`needs_help_api.dart`, `needs_help_sheet.dart`, `needs_help_notifier.dart` — folded into the update sheet), `app/lib/features/cat_detail/ui/cat_update_sheet.dart` + `cat_update_composer_notifier.dart`, `app/lib/core/models/active_alert.dart`, `app/lib/features/cat_detail/` timeline rendering, `app/lib/core/analytics/analytics_events.dart` (`AnalyticsNeedsHelpCategory` removal), notification screens.
- prototype: `prototype/data.js` (`HELP_REASONS`) and `prototype/app.js` help-reason rendering — superseded for the cat-profile surface by `docs/design/screens/cat-profile.html`; the prototype is not updated in this issue.

## open questions

- none beyond the unresolved decisions and open implementation questions listed above.

## out of scope

- api, database, schema, migration, analytics, or flutter implementation (tracked by #101/#102).
- caretaker or moderator capabilities, automated moderation.
- offline queue or synchronization behavior.
- tracking or marking whether an alert was resolved.
