# flutter

## goal

define the mobile app architecture consuming [[api]], scoped to mvp — no more layering than the app currently needs.

## decisions

### stack

- **state/di**: `flutter_riverpod`, plain `Notifier`/`AsyncNotifier` without code generation.
- **routing**: `go_router` for tabs and modal contribution/auth flows.
- **network**: `dio` behind one `ApiClient`; device and bearer credentials use separate interceptors and headers.
- **map**: `google_maps_flutter` with native clustering. clusters separate into individual cat markers as users zoom in; colonies are not a separate mvp entity.
- **push**: `firebase_messaging` remains the eventual mvp-selected client library, but is not wired yet (issue #78 built the needs-help notification feature's ui/data layer against a pull-based `GET /v1/me/notifications` inbox instead — see [[backend]]'s `NotificationSender`/`NOTIFICATION_PROVIDER` note. adding `firebase_messaging` is future work, gated on a real push provider existing to register against).
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
    auth/
    follow/
```

- of this tree, `map/`, `cat_detail/`, `auth/`, `follow/`, `account/`, `add_cat/` (issue #70), `needs_help/` (issue #78), and `notifications/` (issue #78) exist; `add_update/` and `discover/` are still planned, not yet built — ordinary-update composition currently lives inside `cat_detail/ui/` (`CatUpdateSheet`) rather than its own feature slice.
- each feature has a small `data/` and `ui/` boundary; no separate domain layer is required for mvp.
- the approved interactive mvp prototype and `docs/design/implementation-contract.md` are the source of truth for final visual tokens and component behavior.
- `app_theme.dart` implements those approved tokens; visual choices are not left as an architecture open question.
- production maps api keys are injected by the github actions → digitalocean app platform deployment pipeline and restricted separately from development keys.

### identity / auth flow

- device registration remains non-blocking so public browsing works from first launch.
- authenticated actions redirect to phone otp login and return the user to the interrupted flow after success.
- a stale locally-cached device credential (the server no longer recognizes it) self-heals on retry: `AuthNotifier.verifyCode` invalidates it and re-registers before the next attempt, mirroring `cat_update_composer_notifier`'s identical recovery for the same failure mode — see [[api]]'s otp/verify error notes.
- following, ordinary updates, needs-help, media uploads, and new-cat creation require an authenticated account.
- notification permission is requested after following or an explicit notification opt-in, not on first launch. implemented (issue #78) as a local-only prompt `FollowButton` shows at most once per app session after a cat is newly followed (never on unfollow) — both choices are ui-only with no backend call, since there is no real push permission to request yet (see [[backend]]'s `NotificationSender` note); it resets on a cold app start rather than persisting, deliberately not inventing a backend preference field this mvp slice doesn't otherwise need.
- `add_cat/` (issue #70) is the first feature besides follow to call `AuthGate.require` (the map screen's add-cat button); it also introduces this app's first multi-step, single-notifier flow shape (location → non-blocking duplicate check → details/photo/name → submit), mirroring `AuthNotifier`/`LoginScreen`'s one-route, step-switching pattern rather than one go_router route per step. A retried submission (after a transient failure) reuses the same client-generated `Idempotency-Key` for the lifetime of that attempt, matching [[api]]'s retry contract.

## open questions

- none for mvp. exact visual values come from the approved prototype and implementation contract.

## out of scope

- offline-first synchronization.
- colony modeling.
- automated golden-test infrastructure before the mvp ui stabilizes.
