#!/usr/bin/env bash
#
# Apply db/20-post/*.sql to a throwaway PostgreSQL and prove they run.
#
# WHY: nothing in CI executed migration SQL. db-migrate.yml's pull-request job
# runs `db-migrate.sh --dry-run`, which prints filenames and continues -- it never
# executes them -- and the `migrations` job in test.yml is a static check over
# CREATE/DROP statements. Both reported success on a pull request adding two
# migrations without running either. A syntax error, an unsatisfiable constraint
# or a failing assertion would have merged green.
#
# WHAT IT COVERS: ALL of db/20-post, against db/test/fixture.sql, applied twice.
# That is where every security decision in this repository lives -- the settings
# allowlist, the EXECUTE allowlist, the telegram_users scoping, the admin flag
# and the deposit queue -- and, since db/test/Dockerfile, the game loop as well.
#
# 001 AND 002 USED TO BE SKIPPED, and the note here said why: they assert
# wal_level=logical and pg_cron in shared_preload_libraries, and "replaying
# everything needs a custom image". That was true and it was also the entire
# reason game_tick() had no test. game_tick() starts games, calls numbers, closes
# claim windows and fires the payout trigger -- it was the only money-moving code
# in this repository that nothing executed. db/test/Dockerfile is the custom
# image, and it took eight lines.
#
# After the migrations, db/test/game_tick_test.sql drives the loop through a
# whole round and asserts what it did. Applying without erroring is not the same
# as behaving, and for this function the difference is who gets paid.
#
# WHAT IT STILL DOES NOT COVER, stated so nobody mistakes a green run for more
# than it is: db/00-bootstrap and the 104 inherited migrations. The fixture builds
# a production-SHAPED schema, not the real one, so a column that exists here and
# not there is still only caught by the migration run against dev.
#
# Usage:
#   ./scripts/test-migrations.sh                     # podman or docker, ephemeral
#   DATABASE_URL=postgres://... ./scripts/test-migrations.sh   # bring your own

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${GREEN}==>${NC} $*"; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

command -v psql >/dev/null 2>&1 || die "psql not found. Install postgresql-client."

CONTAINER=""; ENGINE=""
cleanup() { [ -n "$CONTAINER" ] && "$ENGINE" rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ -z "${DATABASE_URL:-}" ]; then
  # podman locally (AGENTS.md §3), docker on a GitHub runner. Both accept the
  # same build/run arguments used below.
  #
  # THE CI JOB NO LONGER SUPPLIES ITS OWN DATABASE. It used to start a stock
  # postgres:16 as a `services:` container and pass DATABASE_URL, which meant CI
  # and a developer's machine ran different servers -- and GitHub Actions cannot
  # pass server flags to a service container at all, so shared_preload_libraries
  # could never be set there. That is precisely what kept 001 and 002 skipped.
  # One code path now, and it is this one.
  ENGINE=""
  for e in podman docker; do
    command -v "$e" >/dev/null 2>&1 && { ENGINE="$e"; break; }
  done
  [ -n "$ENGINE" ] || die "neither podman nor docker found, and DATABASE_URL is not set."

  CONTAINER="migration-test-$$"
  PORT="${MIGRATION_TEST_PORT:-55440}"
  IMAGE="fanosbingo-pgtest:16"

  # Built rather than pulled. db/test/Dockerfile is postgres:16 plus pg_cron,
  # which is the whole reason 001 and 002 can now be executed here.
  info "Building $IMAGE with $ENGINE (postgres:16 + pg_cron)"
  "$ENGINE" build -q -f "$REPO_ROOT/db/test/Dockerfile" -t "$IMAGE" "$REPO_ROOT/db/test" >/dev/null \
    || die "could not build the test image"

  # shared_preload_libraries and wal_level are STATIC parameters: they cannot be
  # set after the server is up, which is exactly what db/20-post/001 asserts and
  # tells you to reboot for. Passing them here is the test-server equivalent of
  # the RDS parameter group.
  info "Starting $IMAGE on :${PORT}"
  "$ENGINE" run -d --rm --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=fixture -p "${PORT}:5432" \
    "$IMAGE" \
    -c shared_preload_libraries=pg_cron \
    -c cron.database_name=postgres \
    -c wal_level=logical >/dev/null

  DATABASE_URL="postgresql://postgres:fixture@127.0.0.1:${PORT}/postgres"

  for _ in $(seq 1 40); do
    psql "$DATABASE_URL" -tAc 'SELECT 1' >/dev/null 2>&1 && break
    sleep 2
  done
  psql "$DATABASE_URL" -tAc 'SELECT 1' >/dev/null 2>&1 || die "postgres did not become ready"
fi

PSQL=(psql "$DATABASE_URL" --no-psqlrc --quiet --set ON_ERROR_STOP=1)

echo
echo "${BOLD}Migration test${NC}"
"${PSQL[@]}" -tAc "SELECT '  ' || version()" | head -1

info "Building the fixture"
"${PSQL[@]}" -f "$REPO_ROOT/db/test/fixture.sql" >/dev/null

failed=0

# ALL of them, 001 included. The custom image above provides the pg_cron and
# wal_level that used to force a skip.
for f in "$REPO_ROOT"/db/20-post/*.sql; do
  base="$(basename "$f")"

  printf "  applying %-44s" "$base"

  # --single-transaction so a failure leaves nothing partial, exactly as
  # db-migrate.sh applies them in production.
  if output="$("${PSQL[@]}" --single-transaction -f "$f" 2>&1)"; then
    echo "${GREEN}ok${NC}"
    echo "$output" | grep -E '^(NOTICE|WARNING):' | sed 's/^/        /' || true
  else
    echo "${RED}FAILED${NC}"
    echo "$output" | sed 's/^/        /'
    failed=$((failed + 1))
  fi
done

echo
if [ "$failed" -gt 0 ]; then
  echo "${RED}${BOLD}${failed} migration(s) failed.${NC}"
  exit 1
fi

# Re-apply everything. db/20-post files are REPEATABLE by design -- db-migrate.sh
# re-runs them whenever their content changes -- so one that only works against a
# clean database is broken in a way a single pass cannot see.
info "Re-applying, because these are repeatable and must be idempotent"
for f in "$REPO_ROOT"/db/20-post/*.sql; do
  base="$(basename "$f")"
  printf "  re-applying %-41s" "$base"
  if output="$("${PSQL[@]}" --single-transaction -f "$f" 2>&1)"; then
    echo "${GREEN}ok${NC}"
  else
    echo "${RED}FAILED ON SECOND RUN${NC}"
    echo "$output" | sed 's/^/        /'
    failed=$((failed + 1))
  fi
done

echo
if [ "$failed" -gt 0 ]; then
  echo "${RED}${BOLD}${failed} migration(s) are not idempotent.${NC}"
  exit 1
fi

echo "${GREEN}${BOLD}All migrations applied, twice.${NC}"

# ---------------------------------------------------------------------------
# Behaviour, not just application.
#
# Everything above proves the SQL runs. This drives game_tick() through a whole
# round -- create, roll, start, call, exhaust, claim, pay -- and asserts what it
# actually did. NOT in --single-transaction: the file manages its own state and
# the assertions are more readable when a failure leaves the row it complains
# about visible in the container.
# ---------------------------------------------------------------------------
echo
info "Driving the game loop"
if output="$("${PSQL[@]}" -f "$REPO_ROOT/db/test/game_tick_test.sql" 2>&1)"; then
  # psql prefixes notices with "psql:<file>:<line>: ", so strip that too --
  # otherwise the nine assertions this file exists to report are invisible on a
  # pass, which is the wrong way round.
  echo "$output" | grep -E 'NOTICE:' | sed -E 's/^.*NOTICE:  //' || true
  echo "${GREEN}${BOLD}game_tick behaves.${NC}"
else
  echo "${RED}${BOLD}game_tick FAILED${NC}"
  echo "$output" | sed 's/^/  /'
  exit 1
fi
echo "${YELLOW}Covers all of db/20-post against a production-SHAPED fixture. The bootstrap and the 104 inherited migrations are still only exercised by the run against dev.${NC}"
