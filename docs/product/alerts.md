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

## decisions — lifecycle and constraints (product-owner decisions on issue #101, implemented)

1. **clearing: the author, within 10 minutes; otherwise expiry only.** the user who marked help may remove the mark within the same fixed 10-minute correction window every update already has ([[updates]]) — either by clearing the mark from the update (the flag alone; the update and its statuses survive) or by deleting the whole update. the window and authorship are enforced server-side, never trusted from the client. beyond that window there is still no manual clear or resolve action for anyone; expiry is the only clearing mechanism. legacy pre-migration help records remain non-correctable, as before.
2. **expiry: automatic, exactly 72 hours after marking, decided server-side.** an api read never serves an expired state as active — activeness is derived against the server clock on every read, never left to a client clock. an expired help record stays in the cat's history without active emphasis.
3. **re-marking while a help state is already active: no re-notification; the window restarts.** the update is recorded normally and the 72-hour window follows the newest mark, but followers are not notified again while the state is already active. suppression is decided against the mark's own creation time, so delayed notification dispatch reaches the same verdict.
4. **note constraints.** the note is optional, free text, at most 500 unicode characters (`400` beyond), empty treated as absent. it is public user-generated content under the same visibility, retention, and account-deletion rules as update comments ([[privacy]]); it is never sent to the analytics provider and never included in a push payload. automated moderation is out of scope; existing admin/legal moderation obligations apply unchanged. the cap applies to the help note only — ordinary comments are unchanged.
5. **notification wording: unchanged, already category-free.** push title/body stay `Yardım çağrısı` / `Takip ettiğin bir kedinin yardıma ihtiyacı var.`; the in-app row copy stays `Takip ettiğin bir kedi için yardım bildirimi`. the push data payload's `category` key is dropped (implemented in #101). the trigger rule in [[notifications]] is unchanged in substance: only an update that carries the help option notifies, followers only, subject to decision 3's suppression; statuses alone never notify.
6. **analytics after the category enum retires.** `needs_help_created` remains the event name and loses its `needs_help_category` parameter — it carries no parameters. because one update can now carry both statuses and help, a combined update emits both events: `ordinary_update_created` (with its `update_status` parameter) when at least one status is present, and `needs_help_created` when the help option is set. the `needs_help_category` parameter vocabulary and the corresponding closed enum in `app/lib/core/analytics/analytics_events.dart` are removed in #102. the note is free text and therefore never collected ([[analytics]] "never collected" already covers this). unchanged: `auth_intent: needs_help`, `source: discover_needs_help`, `discover_view: needs_help`, and the discover api's `filter=needs_help` value. the server's compat category value (`unspecified`, below) clamps to a 0.1 client's existing `unknown` bucket — no invalid closed-enum value is ever emitted.

## decisions — migration and compatibility (issue #101, implemented)

binding constraints from issue #100 — existing category-bearing records are not discarded, remain interpretable under mixed 0.1/0.2 clients, and the path is reversible — are implemented as follows (full technical detail in [[db]]/[[api]]):

- **flag model.** `yardıma ihtiyacı var` is a boolean column on the update row, combinable with statuses. existing help-subtype rows are backfilled to the flag with their category and expiry values untouched; the legacy `kind` column freezes as metadata and no read path keys on it.
- **legacy categories: stored, never reproduced.** every stored category value survives in place. the 0.2 interface never renders them — they exist only in the wire compatibility fields 0.1 clients require: an active alert or help-carrying timeline entry always serves `category`/`category_label` — a legacy record's stored value, or the fixed pair `unspecified` / `Yardıma ihtiyacı var` for a post-migration mark. these fields are removed once 0.1 clients are retired.
- **compat endpoint kept.** `POST /v1/cats/{cat_id}/needs-help` keeps serving 0.1 clients unchanged through the mixed-version window; it now writes the flag model and records the submitted category as legacy metadata only. retiring it is deferred until 0.1 clients are retired.
- **reversible rollback, bounded loss.** rolling back restores the 0.1 model bit-for-bit for all pre-migration data; marks created after the migration that carry no category cannot exist in the 0.1 schema and are demoted to plain updates (record and note survive, help aspect drops). rolling forward loses nothing.

## unresolved product decisions

- none. the questions this contract had left open (re-marking, author correction window, migration behavior) were decided on issue #101 and are recorded above.

## affected documents and contracts (0.2 blast radius)

product/design docs (updated or superseded by this contract): `docs/product/alerts.md` (this file), `docs/product/updates.md`, `docs/product/map.md`, `docs/product/analytics.md`, `docs/product/notifications.md`, `docs/design/implementation-contract.md`, `docs/design/screens/cat-profile.html` (imported reference).

api/backend/migration contracts were implemented by #101 (`docs/architecture/api.md`, `docs/architecture/db.md`, migration 00022, backend service/handler/notifier, seed data). remaining for #102 (flutter — no client changes were made in #101):

- flutter: `app/lib/features/needs_help/` (`needs_help_api.dart`, `needs_help_sheet.dart`, `needs_help_notifier.dart` — folded into the update sheet), `app/lib/features/cat_detail/ui/cat_update_sheet.dart` + `cat_update_composer_notifier.dart`, `app/lib/core/models/active_alert.dart`, `app/lib/features/cat_detail/` timeline rendering, `app/lib/core/analytics/analytics_events.dart` (`AnalyticsNeedsHelpCategory` removal), notification screens.
- prototype: `prototype/data.js` (`HELP_REASONS`) and `prototype/app.js` help-reason rendering — superseded for the cat-profile surface by `docs/design/screens/cat-profile.html`; the prototype is not updated by this contract.

## open questions

- none.

## out of scope

- flutter implementation (tracked by #102).
- caretaker or moderator capabilities, automated moderation.
- offline queue or synchronization behavior.
- a resolve/clear action beyond the author's own 10-minute removal window.
