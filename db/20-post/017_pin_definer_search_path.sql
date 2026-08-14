/*
  # Every SECURITY DEFINER function gets a search_path, and pg_temp goes LAST
  #
  # TWO DEFECTS, and the second is the one that matters.
  #
  # ---------------------------------------------------------------------------
  # 1. FOUR FUNCTIONS HAVE NO search_path AT ALL
  #
  #   call_next_bingo_number        20251214082433
  #   ensure_waiting_game_exists    20251223061613
  #   get_server_timestamp          20251219080419
  #   create_game_with_server_time  20251229182827
  #
  # 20251222084140 is titled "fix_function_search_path_final" and missed these
  # four. Two of them are on 004's EXECUTE allowlist, and get_server_timestamp is
  # on the ANON list -- reachable with no token at all.
  #
  # ---------------------------------------------------------------------------
  # 2. `SET search_path = public` DOES NOT DO WHAT THE OTHER 70 FUNCTIONS ASSUME
  #
  # This is the real finding, and it was measured rather than reasoned about.
  # PostgreSQL searches the session's TEMPORARY schema FIRST for relation names
  # when pg_temp is not explicitly listed -- before pg_catalog, before public.
  # So `SET search_path = public` pins the schema for functions and operators and
  # leaves every TABLE reference shadowable.
  #
  # Demonstrated on postgres:16-alpine, two functions differing only in this line:
  #
  #   CREATE TABLE public.telegram_users (id int, won_balance int);
  #   INSERT INTO public.telegram_users VALUES (1, 100);
  #   -- definer function reading telegram_users, attacker has no rights on it:
  #   as attacker: SELECT won_balance FROM public.telegram_users
  #                -> ERROR: permission denied for table telegram_users
  #   as attacker: CREATE TEMP TABLE telegram_users (id int, won_balance int);
  #                INSERT INTO telegram_users VALUES (1, 999999);
  #
  #     SET search_path = public            -> 999999   the attacker's table
  #     SET search_path = public, pg_temp   ->    100   the real one
  #
  # For a definer function that moves money -- select_card_atomic reading a
  # balance, approve_deposit_request crediting one, payout_winners paying out --
  # a shadowed table means the check and the write can disagree about which rows
  # exist.
  #
  # HOW BAD IS IT ACTUALLY, stated honestly because overstating it is how a real
  # finding gets ignored: NOT REACHABLE FROM THE INTERNET TODAY. The attack needs
  # CREATE TEMP TABLE on the session that calls the function, and no HTTP path
  # offers one. PostgREST executes allowlisted RPCs and table access as
  # `authenticated`; it does not run caller-supplied DDL, and 004 already removed
  # every money-moving function from what `authenticated` may EXECUTE. The
  # exposure is a database session: the SSM tunnel, `app_service`, or a
  # compromised container -- i.e. it turns "reached the database as a limited
  # role" into "used a function owned by the master user to act on tables that
  # role cannot touch". That is a privilege-escalation step, not a front door.
  #
  # It is fixed here anyway because it costs one ALTER per function and removes
  # an escalation path, which is the whole shape of defence in depth.
  #
  # ---------------------------------------------------------------------------
  # WHY THIS IS A LOOP AND NOT 74 NAMED STATEMENTS
  #
  # The invariant is "no SECURITY DEFINER function in a schema we own is missing
  # a pinned search_path with pg_temp last". Naming functions restates a list
  # that drifts the moment somebody adds a function -- which is exactly how
  # 20251222084140 came to be titled "final" and miss four. A loop over the
  # catalog is the invariant itself, and re-running it is how drift gets
  # corrected rather than reported.
  #
  # It reads the CATALOG, not the migration files, so it also covers functions
  # this repository never wrote.
  #
  # SAFE TO APPLY: nothing in db/, supabase/migrations/ or services/ creates a
  # temporary table, so no function here resolves a relation through pg_temp on
  # purpose. Putting pg_temp last only removes an implicit first search.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

DO $$
DECLARE
  v_fn        record;
  v_current   text;
  v_desired   text;
  v_pinned    integer := 0;
  v_appended  integer := 0;
BEGIN
  FOR v_fn IN
    SELECT p.oid,
           p.oid::regprocedure AS signature,
           (SELECT c FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) AS c
             WHERE c LIKE 'search_path=%' LIMIT 1) AS config
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.prosecdef                      -- SECURITY DEFINER only
       AND n.nspname IN ('public', 'auth')  -- the schemas this project owns
     ORDER BY 2
  LOOP
    -- The value after the '=', or NULL when the function has no search_path.
    v_current := nullif(substring(v_fn.config FROM 'search_path=(.*)$'), '');

    IF v_current IS NULL THEN
      -- Case 1: no search_path at all. `public` matches what every other
      -- function in this schema resolves against.
      v_desired  := 'public, pg_temp';
      v_pinned   := v_pinned + 1;

    ELSIF btrim(v_current) ~ '(^|,)\s*pg_temp\s*$' THEN
      -- Already correct, and already LAST. Nothing to do.
      CONTINUE;

    ELSIF btrim(v_current) ~ '(^|,)\s*pg_temp\s*(,|$)' THEN
      -- pg_temp is present but NOT last, which is the one arrangement that
      -- looks fixed and is not: everything after it is searched later than the
      -- temporary schema. Rebuild with it moved to the end.
      v_desired := btrim(regexp_replace(v_current, '\s*,?\s*pg_temp\s*', '', 'g'), ' ,')
                   || ', pg_temp';
      v_appended := v_appended + 1;

    ELSE
      -- Case 2: pinned, but shadowable. Keep whatever it names and append.
      v_desired  := btrim(v_current) || ', pg_temp';
      v_appended := v_appended + 1;
    END IF;

    -- regprocedure renders the identity with its argument types and quotes what
    -- needs quoting, so overloads are addressed unambiguously. The value list
    -- is interpolated raw because it is built here, not supplied.
    EXECUTE format('ALTER FUNCTION %s SET search_path = %s', v_fn.signature, v_desired);
  END LOOP;

  RAISE NOTICE 'search_path pinned on % function(s) that had none; pg_temp appended to % more',
    v_pinned, v_appended;
END;
$$;

-- ---------------------------------------------------------------------------
-- Execute the control, do not inspect the statement that was meant to apply it.
--
-- The recurring failure in this repository is a security statement that reports
-- success and changes nothing -- db/20-post/004 documents the ALTER DEFAULT
-- PRIVILEGES case, and 20251222084140 is the case directly above. So this asks
-- the catalog whether the invariant now HOLDS, and fails the migration if it
-- does not.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bad text[];
BEGIN
  SELECT array_agg(sig ORDER BY sig) INTO v_bad
    FROM (
      SELECT p.oid::regprocedure::text AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE p.prosecdef
         AND n.nspname IN ('public', 'auth')
         AND coalesce(
               (SELECT btrim(substring(c FROM 'search_path=(.*)$'))
                  FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) AS c
                 WHERE c LIKE 'search_path=%' LIMIT 1),
               ''
             ) !~ '(^|,)\s*pg_temp\s*$'
    ) bad;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'SECURITY DEFINER function(s) still resolve relations through pg_temp: %',
      array_to_string(v_bad, ', ');
  END IF;

  RAISE NOTICE 'verified: every SECURITY DEFINER function in public and auth ends its search_path with pg_temp';
END;
$$;
