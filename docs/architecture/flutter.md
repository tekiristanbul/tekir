# flutter

## goal

define the mobile app architecture consuming [[api]], scoped to mvp — no more layering than the app currently needs.

## decisions

### stack

- **state/di**: `flutter_riverpod`, plain `Notifier`/`AsyncNotifier` without code generation.
- **routing**: `go_router` for tabs and modal contribution/auth flows.
- **network**: `dio` behind one `ApiClient`; device and bearer credentials use separate interceptors and headers.
- **map**: `google_maps_flutter` with native clustering. clusters separate into individual cat markers as users zoom in; colonies are not a separate mvp entity. the initial camera (issue #235) comes from `LocationService.resolveInitialCenter` (`features/map/data/location_service.dart`): a device position is used only when it's granted, the location service is enabled, and it passes `istanbulBounds.contains` (`core/geo/istanbul_bounds.dart`, the same bounds shared with the add-cat location picker and mirrored server-side by `backend/internal/service/cats.go`'s `istanbulBounds`); any other outcome — denied, disabled, a failed/timed-out read, or a resolved position outside that box — falls back to the fixed `istanbulFallback` point at `istanbulFallbackZoom`, the map's own widest allowed zoom, so the fallback view reads as "istanbul" rather than a single street. Only `initialCameraPosition` is set from this resolution — nothing re-centers the camera afterward, so the fallback can't cause a later camera jump once the map has settled.
- **push**: `firebase_messaging` (implemented — issue #84) behind the app-owned `PushMessagingBackend`/`PushNotificationsService` pair in `core/push/`: permission is requested only from the follow opt-in sheet, the token registers/refreshes via `PUT /v1/devices/me`, and foreground/background/terminated opens deep-link to the cat detail with duplicate-open protection. active only under `NOTIFICATION_PROVIDER=fcm` with an initialized firebase app (`core/firebase/firebase_bootstrap.dart`, `lib/firebase_options.dart` from `flutterfire configure`); the `fake` default keeps the pre-#84 local-only behavior and runs no firebase code. the pull-based `GET /v1/me/notifications` inbox (issue #78) remains the in-app source of truth regardless of push.
- **analytics**: google analytics for firebase (implemented — issue #84) behind the app-owned `AnalyticsService` in `core/analytics/` — a closed, typed event contract (`analytics_events.dart`, documented in docs/product/analytics.md) whose constructors only accept bounded enums, so prohibited values are unrepresentable. `ANALYTICS_PROVIDER` selects `none` (local/test default, noop) or `firebase`; failures never block product actions.
- **secure storage**: `flutter_secure_storage` for device, access, and refresh tokens.
- **media**: `image_picker` for capture/selection (added — issue #70) and `cached_network_image` for display.

### structure

```text
lib/
  core/
    network/
    identity/
    router/
    theme/
  features/
    map/
    cat_detail/
    add_update/
    add_cat/
    discover/
    needs_help/
    notifications/
    account/
    profile/
    badges/
    auth/
    follow/
```

- of this tree, `map/`, `cat_detail/`, `auth/`, `follow/`, `account/`, `add_cat/` (issue #70), `needs_help/` (issue #78), `notifications/` (issue #78), `profile/` (issue #80), `badges/` (issue #80), and `discover/` (issue #80 product-owner review) exist; `add_update/` is still planned, not yet built — ordinary-update composition currently lives inside `cat_detail/ui/` (`CatUpdateSheet`) rather than its own feature slice. `discover/` is deliberately minimal: it shows only the account's followed cats, reusing `GET /v1/me/follows` (`follow/data/follows_api.dart`) rather than a bespoke endpoint — the approved prototype's full discovery scope (all cats by distance, nearby, needs-help tabs) is tracked as a separate follow-up issue, not this slice.
- `account/` remains the settings/logout/guest-gate shell (issue #58's foundation, unchanged in shape by issue #80); `profile/` is the richer, separate authenticated identity surface (display name — editable via `PATCH /v1/me`, contribution totals, badges strip, recent contributions) the approved prototype's own profile screen maps to — its own settings button links into `account/`, mirroring how the prototype keeps "Profil" and "Ayarlar" as two distinct screens rather than one. `core/router/app_shell.dart` now matches the approved prototype's bottom nav exactly (issue #80 product-owner review, correcting the original issue #80 round's gated-corner-button approach, which didn't match this ia): `go_router`'s `StatefulShellRoute.indexedStack` wraps 3 branches — `/` (map), `/discover`, `/profile` — behind a persistent bottom nav bar plus a center-docked add-cat fab; every other route (cat detail, login, account, add-cat, notifications, badges) stays a plain top-level route pushed on top, so the shell's chrome disappears the instant one of those is open, exactly like the prototype's own per-screen nav visibility. `notifications/` is not part of this shell (the approved prototype predates issue #78's notification feature, so there's no prototype ia for it to match) — it stays reachable via its own gated icon button on the map screen (`AuthGate.require`).
- the update-correction sheet (issue #80, `cat_detail/ui/update_correction_sheet.dart`) has no prototype screen to port — the approved prototype's own correction-window logic (`canDeleteUpdate`/`deleteWindowLeft`) was data-layer only, never wired to any rendered screen. Its shell/copy/state conventions are instead drawn from this app's own existing sheets (`CatUpdateSheet`'s status-pill grid, `NeedsHelpSheet`'s inline-error-banner and toast conventions).
- each feature has a small `data/` and `ui/` boundary; no separate domain layer is required for mvp.
- the shipped implementation and `docs/design/implementation-contract.md` are the source of truth for final visual tokens and component behavior.
- `app_theme.dart` implements those approved tokens; visual choices are not left as an architecture open question.
- production maps api keys are injected by the github actions → digitalocean app platform deployment pipeline and restricted separately from development keys.

### identity / auth flow

- device registration remains non-blocking so public browsing works from first launch.
- authenticated actions redirect to phone otp login and return the user to the interrupted flow after success.
- a resumed access token (issue #155) is rotated automatically: `CatsOfIstanbulApp` observes `AppLifecycleState.resumed` and calls `SessionNotifier.refreshIfNeeded`, which is a no-op for a guest or a still-fresh token and otherwise rotates the refresh token exactly like cold-start `restore` — token freshness is judged locally by decoding the access token jwt's own `exp` claim (no signature check; the server is the only party that needs to trust it), so no extra network round trip is spent finding out a token is still valid. A refresh token that's no longer valid clears the session (guest state) instead of leaving the app stuck on a dead credential — the same fallback `restore` already used for a cold start.
- a stale locally-cached device credential (the server no longer recognizes it) self-heals on retry: `AuthNotifier.verifyCode` invalidates it and re-registers before the next attempt, mirroring `cat_update_composer_notifier`'s identical recovery for the same failure mode — see [[api]]'s otp/verify error notes.
- following, ordinary updates, needs-help, media uploads, and new-cat creation require an authenticated account.
- logging out (issue #80 product-owner review) sends the installation's own cached `X-Device-Token` on `POST /v1/auth/logout` (`SessionNotifier.logout`) so the backend can unlink this device from the account being logged out of — fixing a bug where a device once linked to one account could never sign into a different one on the same install. `DeviceIdentityService.invalidate` is never called here: the installation's device identity itself survives a logout unchanged, only its account link changes, server-side. `profileProvider`/`badgesProvider`/`notificationsProvider`/`discoverProvider` each reset to their initial (empty, not-yet-loaded) state the instant the session's account id changes — logout or a fresh different-account login — via `ref.listen` (not `ref.watch`, which would re-run `build()` and unconditionally discard an in-flight load's result) skipping any transition through `AsyncLoading` (`sessionProvider`'s own first-ever cold-start resolution isn't a real account change); each notifier's `load()` also re-checks the account id after its own await, so a slow request from the previous account can never overwrite the next account's freshly-reset state. `followsProvider` already had the equivalent `build()`-time reset from issue #65 (its fetch and reset are the same operation, so it doesn't need this same race-guard).
- notification permission is requested after following or an explicit notification opt-in, not on first launch. the prompt `FollowButton` shows at most once per app session after a cat is newly followed (never on unfollow — issue #78) is now the *approved permission point* (issue #84): under `NOTIFICATION_PROVIDER=fcm`, "İzin ver" requests the real system permission and registers the fcm token; under the local `fake` default both choices remain ui-only with no backend call, exactly the pre-#84 behavior. the asked-once flag still resets on a cold app start — under fcm the system permission state is the durable truth anyway.
- `add_cat/` (issue #70) is the first feature besides follow to call `AuthGate.require` (the map screen's add-cat button, now the shell's center-docked fab — see above); it also introduces this app's first multi-step, single-notifier flow shape (location → non-blocking duplicate check → details/photo/name → submit), mirroring `AuthNotifier`/`LoginScreen`'s one-route, step-switching pattern rather than one go_router route per step. A retried submission (after a transient failure) reuses the same client-generated `Idempotency-Key` for the lifetime of that attempt, matching [[api]]'s retry contract. `cat_detail/ui/cat_update_composer_notifier.dart` (issue #80 product-owner review) uses the identical convention for `POST .../updates`: one key per logical submit attempt, regenerated only after success, so a rapid repeat tap or a retried request can never create a second update row.
- The cat-detail "Gördüm" button's selected/disabled state (issue #80 product-owner review) is derived, never a client-only "just submitted" flag: `cat_detail_screen.dart`'s `_UpdateActionsRow` scans the already-loaded timeline (`CatDetailState.updates`) for the caller's own most recent ordinary update containing `seen` whose `CatUpdateEntry.isCorrectionOpen()` is still true, reusing the existing 10-minute correction window rather than a new, invented cooldown. Another account's update on the same cat never matches (`authorIsMe` is server-derived per entry), and the button re-enables the instant the window closes on the next rebuild.
- `CatUpdateComposerNotifier`'s draft (issue #202) stays keyed per cat id (`catUpdateComposerProvider`'s family, not `autoDispose`) rather than switching to `autoDispose` — an in-flight optimistic submission or media upload must survive the user navigating off the cat-detail screen before it resolves, and `autoDispose` would tear the notifier down mid-request the moment nothing was watching it. The two problems that motivated considering `autoDispose` — a reopened sheet briefly flashing the previous open's leftover media, and a delayed `image_picker` result writing into a draft nobody sees anymore — are solved narrowly instead: the caller resets the draft synchronously before the sheet ever mounts (not in the sheet's own `initState`, which could only do it a frame late via a microtask), and an internal generation counter (bumped by `reset()` and by the sheet's `dispose()`) is captured before every picker await and rechecked after, so a stale result is dropped rather than applied — the same re-check-after-await shape `profileProvider`/`badgesProvider`/etc. already use for a slow request from a previous account (see the identity/auth flow notes above).
- issue #196 collapsed the update-media sheet's four entry points (camera/gallery × photo/video) down to the two the product decision asked for — `Kameradan ekle`, `Galeriden ekle` — but the gallery and camera sides get there differently, because `image_picker` (1.2.3) doesn't support the same thing on both sides. Gallery: `ImagePicker.pickMedia()` wraps the platform's own mixed picker (iOS `PHPicker`, the Android Photo Picker) and returns either a photo or a video from one native flow, so `CatUpdateComposerNotifier.pickMedia()` replaces the old separate `pickPhoto(gallery)`/`pickVideo(gallery)` calls outright. Camera: `image_picker` has no equivalent unified capture call — `pickImage(source: camera)`/`pickVideo(source: camera)` each launch the platform camera locked to one mode, with no option to request "either" — so `Kameradan ekle` still opens one more, camera-only `Fotoğraf çek`/`Video çek` choice before calling the same `pickPhoto`/`pickVideo` methods camera capture already used. Building a custom capture ui to fake a merged camera flow was ruled out (explicitly out of scope on the issue, and disproportionate to a one-tap savings); the two-step camera path is the plugin's own limitation showing through, not a product decision to route photo and video capture differently.

## open questions

- none for mvp. exact visual values come from the shipped implementation and implementation contract.

## out of scope

- offline-first synchronization.
- colony modeling.
- automated golden-test infrastructure before the mvp ui stabilizes.
