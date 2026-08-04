# analytics

## goal

answer a small set of 0.1 product questions — do users reach discovery, open cat details, cross the auth gate when they intend to contribute, complete core contributions, follow cats, and return through needs-help notifications — without ever collecting personal data, content, or precise location.

## decisions

- analytics is a typed, application-owned contract: every event and parameter is defined once, in `app/lib/core/analytics/analytics_events.dart`, and constructed only from closed enums — free strings cannot reach an event.
- google analytics for firebase is the 0.1 provider, behind the app-owned `AnalyticsService` interface; `ANALYTICS_PROVIDER` selects `none` (local/test default) or `firebase` (production 0.1). the provider can be disabled at any time without touching product code.
- analytics failures never block or break a user action; the firebase adapter swallows every error.
- no analytics user id is set, no user properties are registered, and advertising identifiers, ad personalization, audiences, session replay, and cross-app tracking stay disabled.
- debug/test data is separated by provider selection: local development and ci run `ANALYTICS_PROVIDER=none`; local firebase validation uses a non-production firebase project and DebugView.

### event vocabulary (0.1, complete)

```text
onboarding_completed
location_permission_result   result
screen_view                  screen_name
cat_opened                   source
auth_gate_shown              auth_intent
auth_completed               auth_intent
auth_failed                  auth_intent, result
follow_created               source?
follow_removed               source?
ordinary_update_created      update_status
needs_help_created           needs_help_category
cat_created
discover_view_selected       discover_view
notification_permission_result  result
notification_received        notification_state
notification_opened          notification_state
```

### parameter vocabularies

- `source`: `map`, `discover_nearby`, `discover_needs_help`, `discover_following`, `notification`, `profile` — omitted entirely when the surface was reached outside the vocabulary (deep link).
- `screen_name`: `map`, `discover`, `profile`, `cat_detail`, `login`, `account`, `add_cat`, `notifications`, `badges`, `badge_detail` — route templates only, never concrete urls.
- `discover_view`: `nearby`, `needs_help`, `following`.
- `auth_intent`: `follow`, `ordinary_update`, `needs_help`, `add_cat`, `profile`.
- `result`: `success`, `cancelled`, `invalid`, `offline`, `server_error`, `permission_denied`.
- `update_status`: `seen`, `fed`, `water_provided`, `multiple`.
- `needs_help_category`: the fixed 0.1 vocabulary from [[alerts]] (`injured_or_sick`, `food_needed`, `water_needed`, `unsafe_location`, `trapped`), with anything else clamped to `unknown`. **retired in 0.2** by the simplified help contract ([[alerts]], issue #100): `needs_help_created` keeps its name and loses this parameter entirely; the closed enum in `analytics_events.dart` is removed in #102. until #102 lands, the 0.1 vocabulary above remains the implemented contract.
- `notification_state`: `foreground`, `background`, `terminated`.

### never collected

phone numbers or phone-derived hashes, display names, free-text comments, cat names, coordinates/geohashes/addresses/area labels, media urls or object keys, access/refresh/device/push tokens, raw provider responses, account or database ids, notification recipient lists. raw cat ids and update ids are also excluded — behavior is measured through the bounded vocabularies above.

## open questions

- retention: firebase analytics event retention defaults apply until a concrete retention period is chosen alongside the [[privacy]] notice before public launch.

## out of scope

- session replay, screen recording, a/b testing, remote config, audiences, ad attribution.
- product dashboards beyond the standard firebase/ga reports.
- exporting analytics to a data warehouse.
