/// The complete, closed 0.1 analytics event contract (issue #84).
///
/// Every event tekir may emit is defined here, and nowhere else — event
/// names and parameter vocabularies are centralized so the measurement
/// plan stays reviewable in one file. Constructors only accept the enums
/// below, never free strings, so prohibited values (phone numbers, names,
/// free text, coordinates, tokens, raw ids — docs/product/privacy.md and
/// issue #84's privacy constraints) are unrepresentable by construction:
/// there is no way to attach a cat id, an update id, or any user content
/// to an event.
library;

/// Where a cat/follow interaction originated. Matches issue #84's bounded
/// `source` vocabulary one-to-one.
enum AnalyticsSource {
  map('map'),
  discoverNearby('discover_nearby'),
  discoverNeedsHelp('discover_needs_help'),
  discoverFollowing('discover_following'),
  notification('notification'),
  profile('profile');

  const AnalyticsSource(this.wire);

  final String wire;
}

/// The approved screen vocabulary for `screen_view` — route templates, not
/// concrete urls, so path parameters (cat ids, badge ids) never leak into
/// an event.
enum AnalyticsScreen {
  map('map'),
  discover('discover'),
  profile('profile'),
  catDetail('cat_detail'),
  login('login'),
  account('account'),
  addCat('add_cat'),
  notifications('notifications'),
  badges('badges'),
  badgeDetail('badge_detail');

  const AnalyticsScreen(this.wire);

  final String wire;
}

/// Which discover tab the user selected.
enum AnalyticsDiscoverView {
  nearby('nearby'),
  needsHelp('needs_help'),
  following('following');

  const AnalyticsDiscoverView(this.wire);

  final String wire;
}

/// The action a guest intended when the auth gate appeared.
enum AnalyticsAuthIntent {
  follow('follow'),
  ordinaryUpdate('ordinary_update'),
  needsHelp('needs_help'),
  addCat('add_cat'),
  profile('profile');

  const AnalyticsAuthIntent(this.wire);

  final String wire;
}

/// Coarse outcome vocabulary shared by permission and auth events.
enum AnalyticsResult {
  success('success'),
  cancelled('cancelled'),
  invalid('invalid'),
  offline('offline'),
  serverError('server_error'),
  permissionDenied('permission_denied');

  const AnalyticsResult(this.wire);

  final String wire;
}

/// Which statuses an ordinary update carried.
enum AnalyticsUpdateStatus {
  seen('seen'),
  fed('fed'),
  waterProvided('water_provided'),
  multiple('multiple');

  const AnalyticsUpdateStatus(this.wire);

  final String wire;
}

/// The existing fixed needs-help product vocabulary
/// (needsHelpCategoryOptions, docs/product/alerts.md). [fromId] clamps
/// anything outside it to [unknown] instead of ever passing a raw string
/// through.
enum AnalyticsNeedsHelpCategory {
  injuredOrSick('injured_or_sick'),
  foodNeeded('food_needed'),
  waterNeeded('water_needed'),
  unsafeLocation('unsafe_location'),
  trapped('trapped'),
  unknown('unknown');

  const AnalyticsNeedsHelpCategory(this.wire);

  final String wire;

  static AnalyticsNeedsHelpCategory fromId(String id) {
    for (final category in values) {
      if (category != unknown && category.wire == id) return category;
    }
    return unknown;
  }
}

/// The app state a push notification arrived in or was opened from.
enum AnalyticsNotificationState {
  foreground('foreground'),
  background('background'),
  terminated('terminated');

  const AnalyticsNotificationState(this.wire);

  final String wire;
}

/// One analytics event: a name from the fixed 0.1 vocabulary plus bounded
/// string parameters. Instances are only creatable through the named
/// constructors below — the parameter maps are built exclusively from the
/// enums' wire values.
class AnalyticsEvent {
  const AnalyticsEvent._(this.name, [this.params = const {}]);

  final String name;
  final Map<String, String> params;

  /// The user finished (or skipped past) first-launch onboarding.
  const AnalyticsEvent.onboardingCompleted() : this._('onboarding_completed');

  AnalyticsEvent.locationPermissionResult(AnalyticsResult result)
    : this._('location_permission_result', {'result': result.wire});

  AnalyticsEvent.screenView(AnalyticsScreen screen)
    : this._('screen_view', {'screen_name': screen.wire});

  AnalyticsEvent.catOpened(AnalyticsSource source)
    : this._('cat_opened', {'source': source.wire});

  AnalyticsEvent.authGateShown(AnalyticsAuthIntent intent)
    : this._('auth_gate_shown', {'auth_intent': intent.wire});

  AnalyticsEvent.authCompleted(AnalyticsAuthIntent intent)
    : this._('auth_completed', {'auth_intent': intent.wire});

  AnalyticsEvent.authFailed(AnalyticsAuthIntent intent, AnalyticsResult result)
    : this._('auth_failed', {
        'auth_intent': intent.wire,
        'result': result.wire,
      });

  /// [source] is null when the surface the follow happened on wasn't
  /// reached through a vocabulary source (e.g. a direct deep link) — the
  /// parameter is then omitted entirely rather than ever guessed.
  AnalyticsEvent.followCreated(AnalyticsSource? source)
    : this._(
        'follow_created',
        source == null ? const {} : {'source': source.wire},
      );

  AnalyticsEvent.followRemoved(AnalyticsSource? source)
    : this._(
        'follow_removed',
        source == null ? const {} : {'source': source.wire},
      );

  AnalyticsEvent.ordinaryUpdateCreated(AnalyticsUpdateStatus status)
    : this._('ordinary_update_created', {'update_status': status.wire});

  AnalyticsEvent.needsHelpCreated(AnalyticsNeedsHelpCategory category)
    : this._('needs_help_created', {'needs_help_category': category.wire});

  const AnalyticsEvent.catCreated() : this._('cat_created');

  AnalyticsEvent.discoverViewSelected(AnalyticsDiscoverView view)
    : this._('discover_view_selected', {'discover_view': view.wire});

  AnalyticsEvent.notificationPermissionResult(AnalyticsResult result)
    : this._('notification_permission_result', {'result': result.wire});

  AnalyticsEvent.notificationReceived(AnalyticsNotificationState state)
    : this._('notification_received', {'notification_state': state.wire});

  AnalyticsEvent.notificationOpened(AnalyticsNotificationState state)
    : this._('notification_opened', {'notification_state': state.wire});
}
