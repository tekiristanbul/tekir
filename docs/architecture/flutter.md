# flutter

## goal

define the mobile app architecture consuming [[api]], scoped to mvp — no more layering than the app currently needs.

## decisions

### stack

- **state/di**: `flutter_riverpod`, plain `Notifier`/`AsyncNotifier` without codegen.
- **routing**: `go_router` — tabs plus modal routes for add update, add cat, and login.
- **network**: `dio` behind one `ApiClient`. `DeviceInterceptor` attaches `X-Device-Token` when available. a separate auth interceptor attaches `Authorization: Bearer` for authenticated contribution routes.
- **map**: `google_maps_flutter` with native clustering and a local quiet map style.
- **push**: `firebase_messaging`.
- **secure storage**: `flutter_secure_storage` for device, access, and refresh tokens.
- **media**: `image_picker` and `cached_network_image`.

### structure (feature-first, two layers)

```
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
  main.dart
```

feature `data/` directories own api/model mapping; `ui/` owns widgets and riverpod state. no separate domain layer for mvp.

### identity / auth flow

- startup initializes a server-issued device identity without blocking public browsing.
- every request may carry `X-Device-Token` for device association; the token is sent only to the tekir api origin.
- successful otp verification stores access and refresh tokens. a 401 attempts one silent refresh before routing to login.
- every contribution action checks for a valid access token before submission. this includes ordinary updates, needs-help updates, media uploads, and new-cat creation.
- when a logged-out user starts a contribution, `go_router` opens login and returns them to the original flow after successful verification.
- follow/favorite remains device-owned for mvp and does not require account login.

## open questions

- final visual design / `app_theme.dart` contents.
- pin-clustering behavior once colony vs. individual cat is resolved.
- production maps api key injection through ci/deployment.

## out of scope

- offline-first sync.
- automated widget/golden testing setup until the ui stabilizes.
