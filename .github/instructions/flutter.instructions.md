---
applyTo: "app/**/*.dart,app/pubspec.yaml,app/pubspec.lock,app/web/**,app/scripts/**"
---

# flutter

- preserve the existing riverpod state management, go_router navigation, google maps behavior, and design tokens unless the issue explicitly changes them.
- use the relevant `prototype/` screen and design docs as the visual hierarchy and interaction baseline.
- support applicable loading, empty, error, not-found, and missing-data states.
- never show raw coordinates, ids, stack traces, or transport errors to users.
- keep touch targets at least 44 logical pixels and add regression coverage for layout overflow.
- do not use runtime font cdns or add ui dependencies without explicit issue scope.
- do not change maps api behavior outside the assigned issue.
- run `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, and `flutter test` from `app/`.
