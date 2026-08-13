/*
  # RDS post-migration deltas
  #
  # Runs AFTER the 128 Supabase migrations. Reconciles what those migrations
  # assume about Supabase with what RDS actually provides.
  #
  # IDEMPOTENT: safe to re-run.
*/

-- ---------------------------------------------------------------------------
-- 1. Remove the 4-second game loop
--
-- 20251110041730 scheduled `call-bingo-numbers` at '*/3 * * * * *', later
-- amended to a 4-second interval via cron.schedule_in_database. That six-field
-- sub-minute syntax is a Supabase/Timescale fork extension.
--
-- Stock pg_cron on RDS has ONE-MINUTE granularity. It does not reject the
-- sub-minute schedule loudly — it simply never fires it. A game heartbeat that
-- silently stops is the worst failure mode in this system, so the job is
-- removed here rather than left to look scheduled.
--
-- The ticker container owns this now: a 1-second loop holding
-- pg_try_advisory_lock, which also guarantees exactly one caller across however
-- many instances are running.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'call-bingo-numbers';

  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
    RAISE NOTICE 'Removed cron job call-bingo-numbers (id %). The ticker container owns the game loop.', v_jobid;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Schedule the orphaned cleanup functions
--
-- All four were defined and never scheduled, so game_events,
-- game_state_snapshots, user_state and the pending-SMS table grow without
-- bound. On a 20 GiB volume that is a slow-motion outage: when the disk fills,
-- PostgreSQL stops accepting writes entirely.
--
-- Minute granularity is exactly what RDS pg_cron is good at, so unlike the game
-- loop these belong here.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_job record;
  v_schedules constant text[][] := ARRAY[
    ['cleanup-game-events',   '*/5 * * * *',  'SELECT cleanup_old_game_events()'],
    ['cleanup-snapshots',     '*/5 * * * *',  'SELECT cleanup_old_snapshots()'],
    ['cleanup-user-states',   '*/10 * * * *', 'SELECT cleanup_old_user_states()'],
    ['expire-pending-sms',    '*/10 * * * *', 'SELECT expire_old_pending_sms()']
  ];
  v_row text[];
BEGIN
  FOREACH v_row SLICE 1 IN ARRAY v_schedules LOOP
    -- Unschedule first so re-running this file updates an existing schedule
    -- rather than erroring on the duplicate job name.
    SELECT * INTO v_job FROM cron.job WHERE jobname = v_row[1];
    IF FOUND THEN
      PERFORM cron.unschedule(v_job.jobid);
    END IF;

    PERFORM cron.schedule(v_row[1], v_row[2], v_row[3]);
    RAISE NOTICE 'Scheduled % (%)', v_row[1], v_row[2];
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Confirm the realtime publication covers the right tables
--
-- The migrations add games and players. Assert it rather than assume: if either
-- is missing, Realtime connects successfully and delivers nothing, with no
-- error anywhere. That is precisely the class of failure worth failing loudly
-- on at migration time.
--
-- REPLICA IDENTITY is deliberately left at DEFAULT (primary key) rather than
-- FULL. FULL logs the entire previous row on every UPDATE, and `games` is
-- updated every ~3.5 seconds with a growing called_numbers array — the WAL
-- volume would work against max_slot_wal_keep_size. The client filters on the
-- new row's id, which the primary key covers. Revisit only if DELETE-event
-- filtering misbehaves.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text;
BEGIN
  SELECT string_agg(t, ', ')
  INTO v_missing
  FROM unnest(ARRAY['games', 'players']) AS t
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = t
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'Tables missing from supabase_realtime publication: %. Realtime would connect and silently deliver nothing.',
      v_missing;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Grant on tables that already exist
--
-- The bootstrap sets ALTER DEFAULT PRIVILEGES, which only affects objects
-- created afterwards. This catches anything created by a different role, or
-- before the bootstrap ran on a database that already had tables.
--
-- Without these, PostgREST returns "permission denied for table games" even
-- though every RLS policy is correct — RLS decides which rows, table grants
-- decide whether the table is reachable at all.
-- ---------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
-- SELECT ONLY. This read `SELECT, INSERT, UPDATE, DELETE` until 2026-08-13,
-- and db/20-post/012 revoked the writes eleven files later -- so the grant
-- existed only to be removed, and the gap between the two was a window in which
-- every table was client-writable.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;

-- EXECUTE is granted to service_role ONLY.
--
-- This line used to read `TO anon, authenticated, service_role`, which was
-- catastrophic and not obviously so: 30 of the 58 functions in this schema are
-- SECURITY DEFINER, and eight of those take the caller's own identity as an
-- ordinary parameter without checking it. The blanket grant made
-- transfer_balance and process_bnb_withdrawal_request callable by an
-- unauthenticated HTTP request. Verified against the live dev API before it was
-- closed; see db/20-post/004 for the probe and the full account.
--
-- What anon and authenticated may call is an explicit allowlist, in 004. Adding
-- to it should be a deliberate line in a diff, not a side effect of a function
-- being created.
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA public TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Sanity assertions
--
-- Fail the migration rather than discover these at runtime.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF current_setting('wal_level') <> 'logical' THEN
    RAISE EXCEPTION
      'wal_level is "%" but must be "logical". Set rds.logical_replication=1 and REBOOT the instance; it is a static parameter. Realtime cannot work until this is fixed.',
      current_setting('wal_level');
  END IF;

  IF current_setting('shared_preload_libraries') NOT LIKE '%pg_cron%' THEN
    RAISE EXCEPTION
      'pg_cron is not in shared_preload_libraries ("%"). It is a static parameter and needs a reboot.',
      current_setting('shared_preload_libraries');
  END IF;

  RAISE NOTICE 'wal_level=logical and pg_cron loaded. Realtime prerequisites satisfied.';
END $$;
