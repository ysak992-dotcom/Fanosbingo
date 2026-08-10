#!/usr/bin/env bash
#
# Take a freshly applied environment from "migrations ran" to "you can play a
# round".
#
# WHY THIS EXISTS.
#
# `dev` is stood up to test a change and destroyed afterwards, so its database
# starts empty every time. An empty database cannot be tested against: there are
# no players, no balances, no bank to deposit to, and no admin to approve
# anything. Every rebuild therefore ended in the same twenty minutes of psql by
# hand, done slightly differently each time.
#
# That tax is the real risk to an ephemeral environment. It is exactly high
# enough to make "it is only a one-line change, I will test it in prod" the
# tempting option -- which is the thing an ephemeral dev exists to prevent. So
# the fix is to make the rebuild cheap, not to rebuild less.
#
# WHAT IT IS NOT. Not a migration, and not part of db-migrate.sh. Migrations
# describe the schema every environment must have; this describes fictional
# content exactly one environment should ever have. Putting rows like these in
# `supabase/migrations/` would apply them to production the first time anybody
# ran the migrator there.
#
# Usage:
#   source scripts/db-tunnel.sh dev
#   ./scripts/seed-dev.sh
#
#   ./scripts/seed-dev.sh --admin 123456789    # also promote a real Telegram id
#
# Idempotent, on purpose: every row is keyed on a fixed id and upserted, so
# running it twice is the same as running it once. It follows the same rule as
# db/20-post/* for the same reason -- a seed you are afraid to re-run is a seed
# you stop running.

set -euo pipefail

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}==>${NC} $*"; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

ADMIN_TELEGRAM_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --admin) ADMIN_TELEGRAM_ID="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [ -n "$ADMIN_TELEGRAM_ID" ] && ! [[ "$ADMIN_TELEGRAM_ID" =~ ^[0-9]{1,19}$ ]]; then
  die "--admin takes a numeric Telegram user id."
fi

# ---------------------------------------------------------------------------
# THE GUARD. Read this before changing anything above it.
#
# This script inserts fictional players holding fictional balances and a bank
# account that does not exist. Against prod that is not "test data" -- it is a
# corrupted ledger, and `won_balance` on a seeded row is a withdrawal request
# somebody would have to refuse by hand.
#
# So it refuses rather than warns, and it refuses on the DATABASE it is pointed
# at rather than on an argument it was passed. An argument records what you
# meant; DB_HOST records where you actually are, and those come apart precisely
# when it matters -- a leftover tunnel from an earlier session, a second
# terminal, a copied command.
#
# There is deliberately no --force. Seeding production is not a thing to make
# convenient; if you genuinely need rows there, write the INSERT and think about
# it while you do.
# ---------------------------------------------------------------------------
[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set. Run: source scripts/db-tunnel.sh dev"
[ -n "${DB_HOST:-}" ] || die "DB_HOST is not set. This script identifies the target from the tunnel rather than from an argument -- run: source scripts/db-tunnel.sh dev"
command -v psql >/dev/null 2>&1 || die "psql not found."

case "$DB_HOST" in
  *-prod-*|*prod.*)
    die "DB_HOST is ${DB_HOST}. This seeds fictional players and balances and will not run against production." ;;
  *-dev-*|*restore-drill*|localhost|127.0.0.1)
    : ;;
  *)
    die "DB_HOST is ${DB_HOST}, which is not recognisably a dev, restore-drill or local database. Refusing rather than guessing." ;;
esac

info "Target: ${DB_HOST}"

# ---------------------------------------------------------------------------
# Migrations must already be applied.
#
# Checked by asking for a table that only exists afterwards, rather than by
# trusting that whoever ran this also ran the migrator. A seed against a
# half-migrated database fails halfway and leaves rows behind, which is worse
# than not starting.
# ---------------------------------------------------------------------------
applied="$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM schema_migrations" 2>/dev/null || echo "")"
if [ -z "$applied" ] || [ "$applied" = "0" ]; then
  die "No migrations recorded in this database. Run ./scripts/db-migrate.sh first."
fi

for t in telegram_users bank_options withdrawal_bank_options settings; do
  psql "$DATABASE_URL" -tAc "SELECT to_regclass('public.${t}')" | grep -q . \
    || die "Table ${t} does not exist. Migrations are incomplete -- run ./scripts/db-migrate.sh."
done

info "${applied} migrations recorded"

# ---------------------------------------------------------------------------
# The values.
#
# DOMAIN drives game_url, so a seeded environment points at its own Mini App
# rather than at whatever the last environment pointed at. The two settings rows
# below are the exact pair found stale on the live database on 2026-08-09 --
# game_url still naming a bolt.host preview and telegram_bot_username naming a
# bot that is not this one. Seeding them correctly is how a fresh environment
# avoids inheriting that.
# ---------------------------------------------------------------------------
DOMAIN="${DOMAIN:-yisakmesifin.org}"
BOT_USERNAME="${BOT_USERNAME:-BingoNovaaBot}"

info "Seeding settings, banks and test players"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
BEGIN;

-- settings is keyed on id, NOT on a column called key. Anything written as
-- WHERE key = '...' fails with 'column "key" does not exist', which is how a
-- setting was silently ignored for weeks here.
INSERT INTO settings (id, value, description) VALUES
  ('game_url', 'https://app.${DOMAIN}', 'Where /start sends players'),
  ('telegram_bot_username', '${BOT_USERNAME}', 'Bot this deployment answers as')
ON CONFLICT (id) DO UPDATE
  SET value = EXCLUDED.value, updated_at = now();

-- Deposit destinations. The numbers are deliberately unusable: a dev row that
-- looks like a real account is one somebody eventually sends money to.
INSERT INTO bank_options
  (id, bank_name, account_number, account_name, instructions, is_active, display_order) VALUES
  ('dddddddd-0000-4000-8000-000000000001', 'TeleBirr (DEV TEST)', '0900000001',
   'DEV TEST — NOT A REAL ACCOUNT',
   'Development environment. Do not send money. Approve the claim by hand in Admin.', true, 1),
  ('dddddddd-0000-4000-8000-000000000002', 'CBE (DEV TEST)', '1000000000001',
   'DEV TEST — NOT A REAL ACCOUNT',
   'Development environment. Do not send money. Approve the claim by hand in Admin.', true, 2)
ON CONFLICT (id) DO UPDATE
  SET bank_name = EXCLUDED.bank_name, account_number = EXCLUDED.account_number,
      account_name = EXCLUDED.account_name, instructions = EXCLUDED.instructions,
      is_active = EXCLUDED.is_active, display_order = EXCLUDED.display_order,
      updated_at = now();

-- Payout destinations. Names only -- the player supplies their own account.
INSERT INTO withdrawal_bank_options (id, bank_name, is_active, display_order) VALUES
  ('dddddddd-0000-4000-8001-000000000001', 'TeleBirr',                        true, 1),
  ('dddddddd-0000-4000-8001-000000000002', 'Commercial Bank of Ethiopia',     true, 2),
  ('dddddddd-0000-4000-8001-000000000003', 'Awash Bank',                      true, 3)
ON CONFLICT (id) DO UPDATE
  SET bank_name = EXCLUDED.bank_name, is_active = EXCLUDED.is_active,
      display_order = EXCLUDED.display_order, updated_at = now();

-- Three players, chosen to cover the three states the money paths branch on.
--
--   ...001  balance only          -- can join a round, CANNOT withdraw
--   ...002  won_balance           -- the only state a withdrawal is payable from
--   ...003  admin                 -- approves deposits, completes withdrawals
--
-- The second matters most: deposits are never withdrawable, only winnings are,
-- and that is what stops deposit-and-cash-out being a laundering route. A seed
-- with balance and no won_balance cannot exercise the withdrawal path at all.
--
-- Ids are 9-prefixed and sequential so no row here can collide with a real
-- Telegram account.
INSERT INTO telegram_users
  (telegram_user_id, telegram_username, telegram_first_name, telegram_last_name,
   balance, won_balance, deposited_balance, is_admin) VALUES
  (999000001, 'dev_player_one',  'Dev',   'PlayerOne',  500,   0,   500, false),
  (999000002, 'dev_player_two',  'Dev',   'PlayerTwo',  200, 750,   200, false),
  (999000003, 'dev_admin',       'Dev',   'Admin',      100,   0,     0, true)
ON CONFLICT (telegram_user_id) DO UPDATE
  SET balance           = EXCLUDED.balance,
      won_balance       = EXCLUDED.won_balance,
      deposited_balance = EXCLUDED.deposited_balance,
      is_admin          = EXCLUDED.is_admin,
      last_active_at    = now();

COMMIT;
SQL

# ---------------------------------------------------------------------------
# Promoting a real account.
#
# Separate from the block above because it names somebody real, and because
# db/20-post/005 is explicit that admin is granted with database access rather
# than over HTTP. The bootstrap route promotes only the FIRST admin and only its
# own caller; every one after that comes through here.
# ---------------------------------------------------------------------------
if [ -n "$ADMIN_TELEGRAM_ID" ]; then
  # -q, AND compare against the id rather than testing for emptiness.
  #
  # Both halves were found by running this against a throwaway PostgreSQL 16,
  # where promoting an id that does not exist reported "Promoted 424242 to
  # admin". Without -q, psql writes the command status tag to STDOUT -- so a
  # zero-row UPDATE returns the string "UPDATE 0", which is not empty, and the
  # emptiness test passed for exactly the case it was written to catch.
  #
  # Comparing to the id is the belt to that braces: it is true only if the row
  # this was asked about is the row that changed, which is the actual claim
  # being made. A check that cannot fail on the thing it exists to detect is
  # worse than no check, because it is believed.
  updated="$(psql "$DATABASE_URL" -tAqc \
    "UPDATE telegram_users SET is_admin = true WHERE telegram_user_id = ${ADMIN_TELEGRAM_ID} RETURNING telegram_user_id")"
  if [ "$updated" = "$ADMIN_TELEGRAM_ID" ]; then
    info "Promoted ${ADMIN_TELEGRAM_ID} to admin"
  else
    warn "No telegram_users row for ${ADMIN_TELEGRAM_ID}. Open the Mini App once to create it, then re-run with --admin."
  fi
fi

# ---------------------------------------------------------------------------
# Report what is actually in the database, not what was sent to it.
# ---------------------------------------------------------------------------
echo
echo "${BOLD}Seeded${NC}"
psql "$DATABASE_URL" -q <<'SQL'
SELECT 'settings'               AS table, count(*) FROM settings
  WHERE id IN ('game_url','telegram_bot_username')
UNION ALL SELECT 'bank_options',            count(*) FROM bank_options WHERE is_active
UNION ALL SELECT 'withdrawal_bank_options', count(*) FROM withdrawal_bank_options WHERE is_active
UNION ALL SELECT 'test players',            count(*) FROM telegram_users WHERE telegram_user_id BETWEEN 999000001 AND 999999999
UNION ALL SELECT 'admins',                  count(*) FROM telegram_users WHERE is_admin;
SQL

echo
info "Next: open https://app.${DOMAIN} from Telegram and play a round."
warn "These players cannot log in -- login needs Telegram initData, which only Telegram can produce."
warn "They exist so the admin queues, balances and withdrawal path have something to act on."
