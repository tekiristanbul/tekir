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

flutter run -d chrome --web-port 5050 "$@"
