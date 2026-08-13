#!/usr/bin/env bash
#
# Migration runner.
#
# Applies, in order:
#
#   db/00-bootstrap/     Supabase compatibility layer (roles, auth shim,
#                        pg_cron, the supabase_realtime publication).
#                        Must run first or all 128 migrations below fail.
#   supabase/migrations/ The 128 historical migrations, unmodified. This
#                        directory is the provenance record and is never edited.
#   db/20-post/          RDS reconciliation: remove the unschedulable 4-second
#                        cron job, schedule the orphaned cleanups, assert
#                        wal_level.
#
# Two kinds of file, borrowing Flyway's distinction:
#
#   VERSIONED   supabase/migrations/ — immutable history. Applied exactly once.
#               If one changes after being applied the run FAILS: editing an old
#               migration is how a database drifts from its own history, because
#               every other database silently never sees the change.
#
#   REPEATABLE  db/00-bootstrap/ and db/20-post/ — declarative and idempotent.
#               Re-applied whenever their content changes, so drift is corrected
#               rather than reported as an error. These describe a desired end
#               state (roles exist, cron jobs are scheduled), not a one-time
#               transformation.
#
# Each file runs in a single transaction, so a failure leaves nothing partial.
#
# Usage (expects DATABASE_URL, e.g. from scripts/db-tunnel.sh):
#   source scripts/db-tunnel.sh dev
#   ./scripts/db-migrate.sh
#   ./scripts/db-migrate.sh --dry-run     # list what would be applied

set -euo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}==>${NC} $*"; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set. Run: source scripts/db-tunnel.sh <env>"
command -v psql >/dev/null 2>&1 || die "psql not found. Install postgresql-client."

# ON_ERROR_STOP is essential: without it psql reports success after a failed
# statement, and a half-applied migration gets recorded as complete.
PSQL=(psql "$DATABASE_URL" --no-psqlrc --quiet --set ON_ERROR_STOP=1)

echo
echo "${BOLD}Database migrations${NC}"
"${PSQL[@]}" -tAc "SELECT '  ' || current_database() || ' on ' || inet_server_addr() || ' (PostgreSQL ' || current_setting('server_version') || ')'" \
  || die "Cannot connect. Is the tunnel up?"
echo

# ---------------------------------------------------------------------------
# Tracking table
# ---------------------------------------------------------------------------
"${PSQL[@]}" <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS schema_migrations (
  version     text PRIMARY KEY,
  source      text NOT NULL,
  checksum    text NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  duration_ms integer
);
COMMENT ON TABLE schema_migrations IS
  'Applied migrations. checksum is SHA-256 of the file; a mismatch means an already-applied migration was edited.';
SQL

# Milliseconds since the epoch, portably.
#
# `date +%s%3N` ASSUMES GNU coreutils honours the %3N width modifier. Where it
# does not, %N emits nine digits and the "milliseconds" are nanoseconds -- so a
# file taking two seconds produces a duration of 2,000,000,000, and
# schema_migrations.duration_ms is an `integer`:
#
#   ERROR:  integer out of range
#
# Which is a spectacularly unhelpful thing to be told while migrating a
# database. Worse, it is raised by the RECORDING insert, after the migration has
# already been applied and committed -- so the run aborts having done the work
# without writing it down, and the next run re-applies from the top.
#
# Found on 2026-08-13 on an Ubuntu 26.04 workstation; CI never hit it because
# the runners honour %3N. A timing nicety is not worth a failed migration on
# somebody's laptop, so this degrades to whole seconds where it has to.
_now_ms() {
  local t
  t="$(date +%s%3N 2>/dev/null || echo '')"
  case "$t" in
    ''|*[!0-9]*) echo $(( $(date +%s) * 1000 )) ;;
    # 13 digits is milliseconds-since-epoch and will be until the year 2286.
    # Anything longer is a finer unit that %3N failed to truncate.
    ??????????????*) echo $(( $(date +%s) * 1000 )) ;;
    *) echo "$t" ;;
  esac
}

# ---------------------------------------------------------------------------
# Build the ordered file list
#
# Bootstrap and post files are sorted within their directory; the Supabase
# migrations sort by their timestamp prefix, which is what makes their original
# order reproducible.
# ---------------------------------------------------------------------------
mapfile -t FILES < <(
  { find "$REPO_ROOT/db/00-bootstrap" -maxdepth 1 -name '*.sql' 2>/dev/null | sort
    find "$REPO_ROOT/supabase/migrations" -maxdepth 1 -name '*.sql' 2>/dev/null | sort
    find "$REPO_ROOT/db/20-post" -maxdepth 1 -name '*.sql' 2>/dev/null | sort
  }
)

[ "${#FILES[@]}" -gt 0 ] || die "No migration files found"
info "Found ${#FILES[@]} migration files"

applied=0; skipped=0; failed=0

for file in "${FILES[@]}"; do
  rel="${file#"$REPO_ROOT"/}"
  version="$(basename "$file" .sql)"
  # Namespace bootstrap and post files so a Supabase migration can never collide
  # with one of ours, and classify them as repeatable.
  kind="versioned"
  case "$rel" in
    db/00-bootstrap/*) version="00-bootstrap/${version}"; kind="repeatable" ;;
    db/20-post/*)      version="20-post/${version}";      kind="repeatable" ;;
  esac

  checksum="$(sha256sum "$file" | cut -d' ' -f1)"

  # Version strings come from filenames we control, so simple interpolation is
  # safe here; there is no external input to inject with.
  recorded="$("${PSQL[@]}" -tAc \
    "SELECT checksum FROM schema_migrations WHERE version = '${version}'" 2>/dev/null || echo "")"
  recorded="$(echo "$recorded" | tr -d '[:space:]')"

  if [ -n "$recorded" ]; then
    if [ "$recorded" = "$checksum" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$kind" = "versioned" ]; then
      echo "${RED}  CHANGED${NC} $rel"
      echo "          applied checksum: $recorded"
      echo "          current checksum: $checksum"
      failed=$((failed + 1))
      die "Migration '$version' was edited after being applied.
Editing an applied migration means every other database silently misses the
change. Write a NEW migration instead. If the edit is genuinely cosmetic,
update the recorded checksum deliberately:
  UPDATE schema_migrations SET checksum = '$checksum' WHERE version = '$version';"
    fi

    # Repeatable: content changed, so re-apply. This is the intended path for
    # the declarative bootstrap and post files.
    reapply=true
  else
    reapply=false
  fi

  if [ "$DRY_RUN" = true ]; then
    if [ "$reapply" = true ]; then
      echo "  ${YELLOW}would re-apply${NC} $rel (repeatable, content changed)"
    else
      echo "  ${YELLOW}would apply${NC} $rel"
    fi
    applied=$((applied + 1))
    continue
  fi

  if [ "$reapply" = true ]; then
    printf "  re-applying %-67s" "$rel"
  else
    printf "  applying %-70s" "$rel"
  fi
  start_ms=$(_now_ms)

  # --single-transaction so a failure rolls back cleanly. The bootstrap file
  # reads DB_AUTHENTICATOR_PASSWORD from the environment via \getenv rather than
  # a -v flag, so the password never lands in the process list.
  if ! output="$("${PSQL[@]}" \
        --single-transaction \
        -f "$file" 2>&1)"; then
    echo "${RED}FAILED${NC}"
    echo "$output" | sed 's/^/      /'
    failed=$((failed + 1))
    die "Migration failed: $rel (nothing was committed)"
  fi

  duration=$(( $(_now_ms) - start_ms ))

  # Upsert, so a re-applied repeatable file updates its recorded checksum and
  # timestamp rather than colliding on the primary key.
  "${PSQL[@]}" -c \
    "INSERT INTO schema_migrations (version, source, checksum, duration_ms)
     VALUES ('$version', '$rel', '$checksum', $duration)
     ON CONFLICT (version) DO UPDATE
       SET checksum = EXCLUDED.checksum,
           source = EXCLUDED.source,
           applied_at = now(),
           duration_ms = EXCLUDED.duration_ms" >/dev/null

  echo "${GREEN}ok${NC} (${duration}ms)"
  # Surface RAISE NOTICE output; the post-migration file uses it to report what
  # it unscheduled and scheduled.
  echo "$output" | grep -E "^(NOTICE|WARNING):" | sed 's/^/      /' || true
  applied=$((applied + 1))
done

# ---------------------------------------------------------------------------
# Tell PostgREST the schema moved under it.
#
# PostgREST builds a schema cache ONCE, at boot. It does not notice DDL. So a
# migration that adds, drops or changes the signature of anything PostgREST
# exposes leaves the API serving from a picture of a database that no longer
# exists — and the failure is not a clean 404.
#
# THIS COST A LIVE OUTAGE. db/20-post/004 dropped a superseded overload of
# get_lobby_data_instant, leaving one signature. The cache still listed two, so
# every lobby call answered:
#
#   PGRST203  Could not choose the best candidate function between:
#             public.get_lobby_data_instant(user_telegram_id => bigint),
#             public.get_lobby_data_instant(user_telegram_id => bigint, ...)
#
# The migration was correct, the database was correct, and the app was down
# until the container was restarted by hand. Nothing in the pipeline would have
# caught it: the migration reported success, and it WAS a success.
#
# NOTIFY is how PostgREST is meant to be told (db-channel-enabled defaults to
# on, channel `pgrst`). It costs nothing, needs no restart, and is safe to send
# when no listener exists — an unheard NOTIFY is simply discarded.
#
# Not fatal if it fails: the migrations are already committed at this point, and
# a stale cache is recoverable with a restart. Say so loudly instead.
if [ "$DRY_RUN" = false ] && [ "$applied" -gt 0 ]; then
  if "${PSQL[@]}" -c "NOTIFY pgrst, 'reload schema'" >/dev/null 2>&1; then
    info "Told PostgREST to reload its schema cache"
  else
    warn "Could not NOTIFY pgrst. If the API starts returning PGRST202/PGRST203,"
    warn "its schema cache is stale — force a new deployment of the postgrest service:"
    warn "  aws ecs update-service --cluster fanosbingo-<env> --service postgrest --force-new-deployment"
  fi
fi

echo
if [ "$DRY_RUN" = true ]; then
  info "Dry run: ${applied} would be applied, ${skipped} already recorded"
else
  info "Applied ${applied}, skipped ${skipped} already-recorded"
fi
