#!/usr/bin/env bash
#
# Point Telegram at our webhook, WITH a secret token.
#
# Until this runs, /telegram/webhook refuses every request -- it authenticates on
# X-Telegram-Bot-Api-Secret-Token, and Telegram only sends that header if the
# webhook was registered with a secret_token. That is the safe direction to be
# wrong in: a bot that is silent is better than one anybody can forge updates to.
#
# ORDER MATTERS, and getting it backwards takes the bot down:
#
#   1. deploy the functions service (the route exists and refuses everything)
#   2. run this (Telegram starts sending the header, the route starts answering)
#
# That order is safe the FIRST time because no webhook is registered. If one
# already exists and you are rotating the secret, register first and deploy
# second -- otherwise there is a window where the deployed check rejects the
# header Telegram is still sending from the old registration.
#
# THE BOT TOKEN IS NEVER PRINTED and never passed on a command line, where it
# would land in the process list of a shared host. Both secrets are read from
# SSM into variables and used with curl's --data-urlencode.
#
# Usage:
#   ./scripts/register-telegram-webhook.sh [dev|prod]
#   ./scripts/register-telegram-webhook.sh dev --show     # report only, no change
#
# Requires: aws CLI with ssm:GetParameter on /<prefix>/telegram/*, and curl.

set -euo pipefail

ENVIRONMENT="${1:-dev}"
PROJECT="${PROJECT:-fanosbingo}"
PREFIX="${PROJECT}-${ENVIRONMENT}"
MODE="${2:-}"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

DOMAIN="${DOMAIN:-}"
if [ -z "$DOMAIN" ]; then
  DOMAIN="$(aws ssm get-parameter --name "/${PREFIX}/app/api_base_url" \
    --query 'Parameter.Value' --output text 2>/dev/null | sed 's#^https\?://##')"
fi
[ -n "$DOMAIN" ] || { echo "${RED}Could not determine the API host. Set DOMAIN=api.example.org${NC}" >&2; exit 1; }

WEBHOOK_URL="https://${DOMAIN}/functions/v1/telegram/webhook"

echo "${BOLD}==>${NC} Reading secrets from SSM (/${PREFIX}/telegram/*)"
BOT_TOKEN="$(aws ssm get-parameter --name "/${PREFIX}/telegram/bot_token" \
  --with-decryption --query 'Parameter.Value' --output text)"
WEBHOOK_SECRET="$(aws ssm get-parameter --name "/${PREFIX}/telegram/webhook_secret" \
  --with-decryption --query 'Parameter.Value' --output text)"

[ -n "$BOT_TOKEN" ] && [ -n "$WEBHOOK_SECRET" ] || {
  echo "${RED}A secret is empty. Run sync-secrets before registering.${NC}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# ONE BOT CANNOT SERVE TWO ENVIRONMENTS, AND FAILING AT IT IS SILENT.
#
# Telegram allows a bot exactly ONE webhook url. setWebhook does not merge or
# reject -- it REPLACES. So registering this environment with a token another
# environment is already using does not fail: it quietly repoints the other
# environment's bot here, and the first anyone knows is that production's bot
# has gone deaf while every check on production still passes.
#
# There is no way to detect that afterwards from this environment. getWebhookInfo
# for the stolen bot reports a perfectly healthy registration -- pointing at the
# wrong place.
#
# So compare against every OTHER environment's token before touching Telegram.
# Compared by hash: the tokens are never printed, and equality is all that
# matters.
# ---------------------------------------------------------------------------
_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
THIS_HASH="$(_hash "$BOT_TOKEN")"

for other in dev prod; do
  [ "$other" = "$ENVIRONMENT" ] && continue
  other_token="$(aws ssm get-parameter --name "/${PROJECT}-${other}/telegram/bot_token" \
    --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)"
  [ -n "$other_token" ] && [ "$other_token" != "None" ] || continue
  if [ "$(_hash "$other_token")" = "$THIS_HASH" ]; then
    echo "${RED}ERROR:${NC} ${ENVIRONMENT} and ${other} hold the SAME Telegram bot token." >&2
    echo "  A bot has one webhook. Registering ${ENVIRONMENT} would silently repoint" >&2
    echo "  ${other}'s bot at ${DOMAIN}, and ${other} would stop receiving updates" >&2
    echo "  with nothing reporting a fault." >&2
    echo "" >&2
    echo "  Create a separate bot for ${ENVIRONMENT} with @BotFather, set its token as" >&2
    echo "  a TELEGRAM_BOT_TOKEN secret on the ${ENVIRONMENT} GitHub Environment, and" >&2
    echo "  re-run sync-secrets before this." >&2
    exit 1
  fi
done

# Report what Telegram currently believes, before changing it. `has_custom_certificate`
# and the token itself are not printed; `url` and `pending_update_count` are the
# useful parts and neither is sensitive.
echo "${BOLD}==>${NC} Current registration"
CURRENT="$(curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo")"
# No sed here. An earlier version tried to "protect" the url with
# s/"url":"[^"]*"/"url":"&"/ -- where & re-inserts the WHOLE match, producing
# "url":""url":"..."" and invalid JSON, so the report silently became
# "(could not parse getWebhookInfo)". Nothing in the response is sensitive: the
# token is in the request path, not the body.
echo "$CURRENT" | python3 -c '
import json,sys
d = json.load(sys.stdin).get("result", {})
print("      url:", d.get("url") or "(none registered)")
print("      pending updates:", d.get("pending_update_count", 0))
if d.get("last_error_message"):
    print("      last error:", d["last_error_message"], "at", d.get("last_error_date"))
' 2>/dev/null || echo "      (could not parse getWebhookInfo)"

if [ "$MODE" = "--show" ]; then
  echo "${YELLOW}--show given; nothing was changed.${NC}"
  exit 0
fi

echo "${BOLD}==>${NC} Registering ${WEBHOOK_URL}"

# --data-urlencode, so neither secret appears in the process list or in a URL
# that might be logged by a proxy.
#
# allowed_updates is narrowed to `message`: this bot answers commands and
# nothing else, and every update type left out is one Telegram will not send and
# we do not have to authenticate, parse or ignore.
RESPONSE="$(curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
  --data-urlencode "url=${WEBHOOK_URL}" \
  --data-urlencode "secret_token=${WEBHOOK_SECRET}" \
  --data-urlencode 'allowed_updates=["message"]' \
  --data-urlencode 'drop_pending_updates=true')"

if echo "$RESPONSE" | grep -q '"ok":true'; then
  echo "  ${GREEN}registered${NC}"
else
  # Telegram's description is the useful part and contains no secret.
  echo "  ${RED}FAILED${NC}: $(echo "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("description","?"))' 2>/dev/null || echo "$RESPONSE")" >&2
  exit 1
fi

# Prove it took, from Telegram rather than from the exit code above.
echo "${BOLD}==>${NC} Confirming"
curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" | python3 -c '
import json,sys
d = json.load(sys.stdin).get("result", {})
print("      url:", d.get("url") or "(none)")
# getWebhookInfo does NOT report whether a secret_token is set -- an earlier
# version printed has_custom_certificate here, which is about a self-signed
# TLS certificate and is always present. Reporting it as "secret token set"
# would have said "true" whether or not the secret was registered, which is
# the one thing this step exists to confirm. The real confirmation is
# behavioural: send /start and see whether the bot answers.
print("      allowed updates:", d.get("allowed_updates") or "(all)")
' 2>/dev/null || true

echo
echo "${GREEN}Done.${NC} Send /start to the bot; it should reply with the game link."
echo "If it does not, check the functions log for webhook_rejected:"
echo "  aws logs filter-log-events --log-group-name /ecs/${PREFIX} \\"
echo "    --filter-pattern '\"webhook_\"' --start-time \$(( (\$(date +%s) - 600) * 1000 ))"
