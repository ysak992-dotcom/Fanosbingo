# PostgreSQL for the migration harness, with the two things RDS provides and a
# stock image does not.
#
# WHY THIS IMAGE EXISTS
#
# scripts/test-migrations.sh used to skip db/20-post/001 and 002 with this note:
#
#   "The bootstrap asserts wal_level=logical and pg_cron in
#    shared_preload_libraries, correctly, and neither is available in a stock
#    postgres:16. Replaying everything needs a custom image."
#
# The skip was honest, and it left game_tick() -- the function that starts games,
# calls numbers, closes claim windows and triggers the payout -- as the only
# money-moving code in this repository with no automated coverage at all. Every
# security decision in db/20-post was executed by the harness; the game loop was
# not executed by anything.
#
# This is the custom image. It is the whole of what was missing.
#
# WHY debian AND NOT alpine
#
# The postgres:16 image already has the PGDG apt repository configured, so
# pg_cron is one `apt-get install` away -- seconds, and a package the PostgreSQL
# project builds. On alpine it would be a source build (gcc, llvm, clang,
# postgresql-dev) taking minutes on every CI run, to produce the same extension.
#
# The production database is RDS, which is neither of these, so the base image
# is a test-fidelity question rather than a parity one: what matters is that the
# extension and the WAL level match, and both do.
#
# NOT FOR DEPLOYMENT. Nothing pushes this to ECR. It exists to be run, asserted
# against, and thrown away.
FROM docker.io/library/postgres:16

# Pinned to the major version of the base image. postgresql-16-cron and
# postgres:16 must agree or the extension will not load.
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-cron \
 && rm -rf /var/lib/apt/lists/*

# shared_preload_libraries and wal_level are STATIC parameters -- they cannot be
# set with ALTER SYSTEM at runtime, which is exactly why db/20-post/001 asserts
# them and tells you to reboot. They are passed as server arguments by
# scripts/test-migrations.sh rather than baked in here, so the harness stays the
# single place that describes how the test server is configured.
