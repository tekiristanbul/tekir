# flutter

## goal

define the mobile app architecture consuming [[api]], scoped to mvp — no more layering than the app currently needs.

## decisions

### stack

- **state/di**: `flutter_riverpod`, plain `Notifier`/`AsyncNotifier` without code generation.
- **routing**: `go_router` for tabs and modal contribution/auth flows.
- **network**: `dio` behind one `ApiClient`; device and bearer credentials use separate interceptors and headers.
- **map**: `google_maps_flutter` with native clustering. clusters separate into individual cat markers as users zoom in; colonies are not a separate mvp entity.
- **push**: `firebase_messaging`.
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
    notifications/
    account/
    auth/
    follow/
```

- of this tree, `map/`, `cat_detail/`, `auth/`, `follow/`, `account/`, and `add_cat/` (issue #70) exist; `add_update/`, `discover/`, and `notifications/` are still planned, not yet built — ordinary-update composition currently lives inside `cat_detail/ui/` (`CatUpdateSheet`) rather than its own feature slice.
- each feature has a small `data/` and `ui/` boundary; no separate domain layer is required for mvp.
- the approved interactive mvp prototype and `docs/design/implementation-contract.md` are the source of truth for final visual tokens and component behavior.
- `app_theme.dart` implements those approved tokens; visual choices are not left as an architecture open question.
- production maps api keys are injected by the github actions → digitalocean app platform deployment pipeline and restricted separately from development keys.

### identity / auth flow

- device registration remains non-blocking so public browsing works from first launch.
- authenticated actions redirect to phone otp login and return the user to the interrupted flow after success.
- following, ordinary updates, needs-help, media uploads, and new-cat creation require an authenticated account.
- notification permission is requested after following or an explicit notification opt-in, not on first launch.
- `add_cat/` (issue #70) is the first feature besides follow to call `AuthGate.require` (the map screen's add-cat button); it also introduces this app's first multi-step, single-notifier flow shape (location → non-blocking duplicate check → details/photo/name → submit), mirroring `AuthNotifier`/`LoginScreen`'s one-route, step-switching pattern rather than one go_router route per step. A retried submission (after a transient failure) reuses the same client-generated `Idempotency-Key` for the lifetime of that attempt, matching [[api]]'s retry contract.

## open questions

- none for mvp. exact visual values come from the approved prototype and implementation contract.

## out of scope

- offline-first synchronization.
- colony modeling.
- automated golden-test infrastructure before the mvp ui stabilizes.
