# flutter

## goal

define the mobile app architecture consuming [[api]], scoped to mvp — no more layering than the app currently needs.

## decisions

### stack

- **state/di**: `flutter_riverpod`, plain `Notifier`/`AsyncNotifier` (no codegen). there's one data source (the backend), so a separate domain/repository-interface layer isn't earning its keep yet.
- **routing**: `go_router` — tabs (map / discover / notifications / account) plus modal routes (add update, add cat, login).
- **network**: `dio` behind a single `ApiClient`; an interceptor attaches `X-Device-Id` (and `Authorization: Bearer` when present) to every request, matching [[api]]'s auth model.
- **map**: `google_maps_flutter` + `google_maps_cluster_manager` for pin clustering.
- **push**: `firebase_messaging`; token refreshes call `PUT /v1/devices/{id}`.
- **secure storage**: `flutter_secure_storage` for `device_id` and `access_token`.
- **media**: `image_picker` for capture/selection, `cached_network_image` for display.

### structure (feature-first, two layers)

```
lib/
  core/
    network/        api_client.dart, device_interceptor.dart
    identity/        device_identity.dart   (generate/persist uuid, register with backend on first launch)
    router/          app_router.dart
    theme/           app_theme.dart          (placeholder until the visual design is finalized)
  features/
    map/             data/cats_api.dart · ui/map_screen.dart, cat_pin.dart
    cat_detail/
    add_update/
    add_cat/
    discover/
    notifications/
    account/
    auth/            data/auth_api.dart · ui/login_screen.dart
  main.dart
```

each feature's `data/` holds json↔model mapping and api calls; `ui/` holds widgets and riverpod providers/notifiers. no separate `domain/` layer — introducing repository interfaces now would be abstraction with no second implementation to justify it.

### identity / auth flow

- on startup, a `deviceIdentityProvider` checks secure storage for a `device_id`; if absent, generates a uuid, registers it via `POST /v1/devices`, and stores the push token.
- every `dio` request goes through the interceptor: `device_id` is always attached; `access_token`, when present, is attached too.
- a successful `POST /v1/auth/otp/verify` stores `access_token` in secure storage. because the backend already keys history by `device_id`, no client-side merge step is needed.
- actions that require media (add update with a photo, add cat) check for `access_token` first; if absent, `go_router` pushes the login route, and a successful login pops back to where the user left off — matching the login/phone-verification flow from the ux pass.

## open questions

- final visual design / `app_theme.dart` contents — depends on the design pass, not yet finalized to real tokens.
- pin-clustering behavior once colony vs. individual cat ([[cats]]) is resolved.

## out of scope

- offline-first sync — not attempted at mvp scale, given how much of the data model (duplicate merge, status vocabulary) is still unsettled.
- automated widget/golden testing setup — deferred until the ui stabilizes past mvp.
