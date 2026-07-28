#!/usr/bin/env bash
# runs the flutter web app with the google maps api key injected into
# web/index.html for the duration of the run, then restores the
# placeholder on exit — so a real key never sits committed in git.
#
# usage:
#   GOOGLE_MAPS_API_KEY=... ./scripts/run_web.sh
#   # or put GOOGLE_MAPS_API_KEY=... in app/.env.local (gitignored, see
#   # .env.local.example)
#
# fixed port (5050) so the dev key can be restricted in the google cloud
# console to exactly this origin: http://localhost:5050
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .env.local ]; then
  set -a
  # shellcheck disable=SC1091
  source .env.local
  set +a
fi

if [ -z "${GOOGLE_MAPS_API_KEY:-}" ]; then
  echo "GOOGLE_MAPS_API_KEY is not set (export it, or put it in app/.env.local)" >&2
  exit 1
fi

index_html="web/index.html"
placeholder="__GOOGLE_MAPS_API_KEY__"

restore() {
  sed -i.bak "s|key=[^\"]*|key=${placeholder}|" "$index_html" && rm -f "${index_html}.bak"
}
trap restore EXIT

sed -i.bak "s|key=[^\"]*|key=${GOOGLE_MAPS_API_KEY}|" "$index_html" && rm -f "${index_html}.bak"

# under wsl, `flutter run -d chrome` tries to launch the windows chrome.exe
# (there's no linux chrome binary) but hands it a linux-side --user-data-dir
# path (/tmp/...), which windows chrome can't resolve — it fails to launch
# every time. `-d web-server` sidesteps that: flutter just serves the app,
# and you open it yourself in whatever browser is already running on
# windows. use chrome or edge, not firefox — the debug/hot-reload bridge
# (dwds) only supports chromium-based browsers.
# forward optional provider settings from the environment/.env.local as
# --dart-define flags (issue #84). unset values keep the in-app defaults
# (ANALYTICS_PROVIDER=none, NOTIFICATION_PROVIDER=fake).
dart_defines=()
for var in API_BASE_URL ANALYTICS_PROVIDER NOTIFICATION_PROVIDER FCM_VAPID_KEY; do
  if [ -n "${!var:-}" ]; then
    dart_defines+=(--dart-define "${var}=${!var}")
  fi
done

if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "wsl detected: running as web-server — open http://localhost:5050 in chrome or edge yourself." >&2
  flutter run -d web-server --web-port 5050 ${dart_defines[@]+"${dart_defines[@]}"} "$@"
else
  flutter run -d chrome --web-port 5050 ${dart_defines[@]+"${dart_defines[@]}"} "$@"
fi
