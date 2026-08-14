#!/bin/bash
# Adds issue #241's moderation configuration to /opt/tekir/.env.production.
#
# Run it ON THE SERVER. The api token is read from a prompt with echo off and
# written straight into the env file: it is never passed as an argument (which
# would put it in the process list), never printed, and never lands in shell
# history. Existing MODERATION_* / CLOUDFLARE_* lines are replaced rather than
# duplicated, so re-running it is how you rotate the token.
#
#   scp .deploy/set-moderation-secrets.sh root@<host>:/opt/tekir/
#   ssh root@<host> 'cd /opt/tekir && bash set-moderation-secrets.sh'
#
# The api only reads these once a build containing the moderation feature is
# deployed; adding them earlier is harmless, and doing it earlier is better —
# a build that starts without them refuses to start at all, by design.
set -eu

ENV_FILE="${ENV_FILE:-/opt/tekir/.env.production}"
ACCOUNT_ID_DEFAULT="a18ec07b9c9f3be0a55e26f46bd87369"
TEXT_MODEL_DEFAULT="@cf/google/gemma-4-26b-a4b-it"
VISION_MODEL_DEFAULT="@cf/moondream/moondream3.1-9B-A2B"

[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE — run this on the server" >&2; exit 1; }

read -r -p "cloudflare account id [$ACCOUNT_ID_DEFAULT]: " account_id
account_id="${account_id:-$ACCOUNT_ID_DEFAULT}"

# -s: no echo. The token never appears on screen, and because it arrives on
# stdin rather than argv it is not visible in `ps` either.
read -r -s -p "cloudflare api token (input hidden): " api_token
echo
[ -n "$api_token" ] || { echo "empty token, nothing written" >&2; exit 1; }

read -r -p "text model [$TEXT_MODEL_DEFAULT]: " text_model
text_model="${text_model:-$TEXT_MODEL_DEFAULT}"
read -r -p "vision model [$VISION_MODEL_DEFAULT]: " vision_model
vision_model="${vision_model:-$VISION_MODEL_DEFAULT}"

backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$ENV_FILE" "$backup"

tmp="$(mktemp)"
chmod 600 "$tmp"
grep -vE '^(MODERATION_PROVIDER|MODERATION_TEXT_MODEL|MODERATION_VISION_MODEL|CLOUDFLARE_ACCOUNT_ID|CLOUDFLARE_API_TOKEN)=' "$ENV_FILE" > "$tmp"
{
  echo "MODERATION_PROVIDER=cloudflare"
  echo "MODERATION_TEXT_MODEL=$text_model"
  echo "MODERATION_VISION_MODEL=$vision_model"
  echo "CLOUDFLARE_ACCOUNT_ID=$account_id"
  echo "CLOUDFLARE_API_TOKEN=$api_token"
} >> "$tmp"

cat "$tmp" > "$ENV_FILE"
rm -f "$tmp"
chmod 600 "$ENV_FILE"

# Only the key names, never the values.
echo "wrote to $ENV_FILE (backup: $backup):"
grep -oE '^(MODERATION_[A-Z_]+|CLOUDFLARE_[A-Z_]+)=' "$ENV_FILE" | sed 's/=$//'
echo
echo "the running api does not read these until a build with moderation is deployed."
