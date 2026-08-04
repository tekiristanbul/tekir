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

## decisions — 0.2 simplified help contract (issue #100)

accepted in the issue:

- help is one explicit state: a cat either needs help or it does not. a single boolean flag with an optional free-text note.
- the user-facing action is one action with the copy **`yardıma ihtiyacı var`**. the user is never asked to choose food, water, veterinary, shelter, or any other category. category selection is removed from the 0.2 user experience entirely.
- the active help state and its note are shown on the cat profile.
- the existing normal update flow is preserved; marking help is not a replacement for recording an observation.
- caretaker and moderator workflows are out of scope.
- copy and layout follow the approved cat-profile design at `docs/design/screens/cat-profile.html` (imported by this issue). its binding copy:
  - update-sheet toggle: `yardım`
  - notification banner in the sheet: `takipçilere bildirim gider`
  - note placeholder: `ne oldu? kısaca yaz — yardıma gelen anlasın`
  - submit button with help selected: `yardım çağrısıyla paylaş`
  - timeline chip on a help-bearing record: `yardım gerekiyor`
  - the design's own binding note: `mama` and `su` in the sheet record **work done** (`mama verildi`, `su verildi`), never a need category. the header strip shows what was last *done*, not what is needed.

## proposed decisions — pending product-owner approval

these answer the six questions issue #100 requires this contract to decide. none is implemented; each needs explicit product-owner approval recorded on the issue before #101/#102 start.

1. **migration of existing category-bearing records (non-destructive, reversible).** existing `needs_help_category` values are retained in place as legacy metadata — never rewritten, backfilled, or deleted. for display in 0.2, a legacy record with no comment serves its stored category's turkish label as a generated note (so "mama gerekiyor" keeps its meaning); a legacy record with a comment shows the comment, and the category chip disappears from the ui. rollback to 0.1 behavior needs no data repair because nothing was destroyed.
2. **clearing authority: nobody.** 0.2 keeps the 0.1 rule — there is no manual clear or resolve action for anyone (author included); expiry is the only clearing mechanism. known consequence to weigh: a mistaken help mark notifies all followers immediately and stands for 72 hours (see unresolved decision 4 on the author correction window).
3. **expiry: unchanged.** a help state expires automatically exactly 72 hours after it is marked. an expired help record stays in the cat's history without active emphasis.
4. **note constraints.** the note is optional, free text, at most 500 unicode characters, trimmed, empty treated as absent. it is public user-generated content under the same visibility, retention, and account-deletion rules as update comments ([[privacy]]); it is never sent to the analytics provider and never included in a push payload. automated moderation is out of scope; existing admin/legal moderation obligations apply unchanged.
5. **notification wording: unchanged, already category-free.** push title/body stay `Yardım çağrısı` / `Takip ettiğin bir kedinin yardıma ihtiyacı var.`; the in-app row copy stays `Takip ettiğin bir kedi için yardım bildirimi`. the only 0.2 change is wire-level: the push data payload's `category` key is dropped. the trigger rule in [[notifications]] (only a newly created active help state notifies, followers only) is unchanged.
6. **analytics after the category enum retires.** `needs_help_created` remains the event name and loses its `needs_help_category` parameter — it carries no parameters. the `needs_help_category` parameter vocabulary and the corresponding closed enum in `app/lib/core/analytics/analytics_events.dart` are removed in #102. the note is free text and therefore never collected ([[analytics]] "never collected" already covers this). unchanged: `auth_intent: needs_help`, `source: discover_needs_help`, `discover_view: needs_help`, and the discover api's `filter=needs_help` value.

### mixed 0.1/0.2 client compatibility (proposed)

0.1 clients require `category` and `category_label` to be non-null wherever an active alert or needs-help record appears. during mixed operation the server therefore keeps serving both fields: a legacy record serves its stored values unchanged (0.1 rendering is untouched), and a 0.2-created record serves the fixed pair `category: "unspecified"`, `category_label: "Yardıma ihtiyacı var"`. 0.2 clients ignore both fields. a 0.1 client's `needs_help_created` analytics event clamps `"unspecified"` to `unknown`, which its contract already defines. the fields are removed from responses only after 0.1 clients are retired, as a follow-up decision.

### target api shape (0.2 — definition only; migration is #101, not this issue)

baseline: the existing separate endpoint is retained with the category field removed. the api field name stays `comment` (the user-facing turkish term is "not") to avoid a needless wire rename.

```text
POST /v1/cats/{cat_id}/needs-help  (Bearer required)  { comment? }
  → 201 { id, kind, comment|null, created_at,
          needs_help_expires_at, needs_help_active }

active_alert: { comment|null, created_at, expires_at,
                category, category_label } | null
  — category/category_label only for 0.1 compatibility, per the rule above
```

`400` no longer has a missing/unknown-category case; a comment over the length limit is `400`. everything else (auth, expiry computation, transactional outbox enqueue, error taxonomy) is unchanged from the implemented contract in [[api]]. note: this baseline is contingent on unresolved decision 1 below — if help becomes a flag on the ordinary update, the endpoint folds into `POST /v1/cats/{cat_id}/updates` instead.

## unresolved product decisions — must be answered before #101/#102

listed explicitly instead of silently derived; each blocks the dependent implementation issues.

1. **update model: separate record or flag on an update?** the approved design's update sheet offers `yardım` as a toggle next to `gördüm`/`mama`/`su`, and its timeline shows one record carrying both `yardım gerekiyor` and `su verildi`. the current contract makes `ordinary` and `needs_help` mutually exclusive subtypes (a needs-help record carries no statuses). does 0.2 keep them separate (the target api baseline above), or does help become a flag a single update may carry together with statuses, as the design draws it? this decides the target api and schema for #101. a sub-question either way: a help mark with no status and no note is presumed valid — confirm.
2. **re-marking while a help state is already active.** today a second needs-help post creates a new record and a second follower fan-out. with a boolean state, is marking an already-helping cat rejected, idempotent (no new window, no new notification), or does it restart the 72-hour window and notify again? this defines both the api semantics and the notification-spam surface.
3. **display of legacy category text** — confirm proposed decision 1's generated-note rule, or choose pure legacy-metadata retention where 0.2 shows only the bare help mark and old category labels stop being user-visible.
4. **author correction window.** correction/deletion currently excludes needs-help records entirely (`404`). does that stay in 0.2, given a mistaken single-tap help mark now notifies all followers with no undo? (interacts with proposed decision 2.)

## affected documents and contracts (0.2 blast radius)

product/design docs (updated or superseded by this contract): `docs/product/alerts.md` (this file), `docs/product/updates.md`, `docs/product/map.md`, `docs/product/analytics.md`, `docs/product/notifications.md`, `docs/design/implementation-contract.md`, `docs/design/screens/cat-profile.html` (imported reference).

contracts to change in #101 (api/backend) and #102 (flutter) — no code changes in this issue:

- `docs/architecture/api.md` — `active_alert` shape, `POST .../needs-help` body, category vocabulary paragraphs.
- `docs/architecture/db.md` + schema — `updates.needs_help_category` check constraint and column disposition (retained as legacy metadata under proposed decision 1).
- backend: `internal/service/cats.go` (`CreateNeedsHelpUpdate` category validation), `internal/handler/cats.go`, `internal/service/notifications.go` + `notification_sender.go` + `fcm_notification_sender.go` (push data `category` key), seed data.
- flutter: `app/lib/features/needs_help/` (`needs_help_api.dart`, `needs_help_sheet.dart`, `needs_help_notifier.dart` — category picker removal), `app/lib/core/models/active_alert.dart`, `app/lib/features/cat_detail/` timeline rendering, `app/lib/core/analytics/analytics_events.dart` (`AnalyticsNeedsHelpCategory` removal), notification screens.
- prototype: `prototype/data.js` (`HELP_REASONS`) and `prototype/app.js` help-reason rendering — superseded for the cat-profile surface by `docs/design/screens/cat-profile.html`; the prototype is not updated in this issue.

## open questions

- none beyond the unresolved decisions listed above.

## out of scope

- api, database, schema, migration, analytics, or flutter implementation (tracked by #101/#102).
- caretaker or moderator capabilities, automated moderation.
- offline queue or synchronization behavior.
- tracking or marking whether an alert was resolved.
