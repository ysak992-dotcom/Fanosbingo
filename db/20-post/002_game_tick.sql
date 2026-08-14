/*
  # game_tick(): the server-authoritative game loop
  #
  # Replaces FIVE behaviours that the browser currently owns. Today the game
  # only progresses while somebody has a tab open: if the last player closes the
  # lobby mid-countdown, the game never starts; if nobody is watching a stalled
  # game, it never recovers. That is not a property a real-money game can have.
  #
  #   1. Call the next number          (was pg_cron @ 4s -- unschedulable on RDS)
  #   2. Start a game when its countdown expires   (was Lobby.tsx:433)
  #   3. Roll the countdown when nobody joined     (was Lobby.tsx:445)
  #   4. Close an expired claim window and finish  (was a setTimeout AFTER the
  #                                                 HTTP response in claim-bingo)
  #   5. Ensure a waiting game always exists       (was Lobby.tsx:483)
  #
  # Point 4 deserves emphasis: claim-bingo/index.ts:52 schedules payout
  # finalization with setTimeout AFTER returning its response. Serverless
  # runtimes may freeze the isolate the moment a response is sent, so that
  # callback is not guaranteed to run -- and when it does not, winners are never
  # paid and the game never leaves 'playing'. It also queried
  # status='playing' with no game-id filter, so with two concurrent games it
  # could finalize the wrong one.
  #
  # Everything happens in ONE transaction with row locks. The previous
  # call_next_bingo_number() read last_number_called_at with a plain SELECT and
  # then UPDATEd, so two concurrent callers could both observe the same value
  # and both append a number. FOR UPDATE SKIP LOCKED makes that impossible.
  #
  # Returns a jsonb summary the ticker uses for logging and CloudWatch metrics.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- ---------------------------------------------------------------------------
-- secure_random_int(n) -> a uniform integer in [1, n], from a CSPRNG
--
-- WHY NOT random(), WHICH IS WHAT THIS REPLACES
--
-- PostgreSQL's random() is a fast non-cryptographic PRNG (xoshiro256** in 15+),
-- seeded per session and advanced deterministically. It is the right function
-- for sampling a table and the wrong one for deciding who wins money:
--
--   * Its state is recoverable from its output. An observer who sees enough
--     draws can compute the sequence, and in this game every draw is PUBLISHED
--     -- `called_numbers` is readable by anon, because the board has to render.
--     So the observations are handed out for free.
--   * setseed() makes it reproducible on purpose. Anything able to call it on
--     the ticker's session fixes the whole game's outcome, and it is not a
--     privileged function.
--   * It is not auditable as fair. "We used the default PRNG" is not an answer
--     to a player asking whether a draw was rigged, and it is not an answer a
--     gaming regulator accepts either.
--
-- None of that is a live exploit today -- reaching either weakness needs the
-- ticker's own database session, which is the same access that could simply
-- UPDATE called_numbers. It is here because a real-money draw should not rest
-- on a generator whose documentation says it is unsuitable for the purpose.
--
-- gen_random_bytes() is pgcrypto, enabled in db/00-bootstrap/001 (which notes
-- that gen_random_BYTES is pgcrypto-only, unlike gen_random_UUID).
--
-- WHY REJECTION SAMPLING RATHER THAN A MODULO
--
-- `r % n` is biased whenever n does not divide the generator's range: the first
-- (range mod n) values become fractionally likelier. At n = 75 over 2^32 the
-- bias is about 1 part in 57 million, which is nothing -- and "the bias is
-- small" is exactly the sentence an auditor should not have to accept. Drawing
-- again on the rare out-of-range value removes it entirely, at a cost of one
-- extra draw roughly once every 57 million calls.
--
-- The loop is bounded anyway. Not because 100 consecutive rejections is
-- plausible -- it has probability below 10^-800 -- but because an unbounded
-- loop inside the game's heartbeat is not something to leave to arithmetic.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION secure_random_int(p_upper integer)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- 2^32. The draw below builds a 32-bit value from four bytes.
  c_range  constant bigint := 4294967296;
  v_bytes  bytea;
  v_draw   bigint;
  v_limit  bigint;
  v_tries  integer := 0;
BEGIN
  IF p_upper IS NULL OR p_upper < 1 THEN
    RAISE EXCEPTION 'secure_random_int requires an upper bound of at least 1, got %', p_upper;
  END IF;

  -- The largest multiple of p_upper that fits in the range. Draws at or above
  -- it are the ones that would skew a modulo, so they are discarded.
  v_limit := (c_range / p_upper) * p_upper;

  LOOP
    v_tries := v_tries + 1;

    -- Assembled with get_byte rather than a bit-string cast, so the value is
    -- unambiguously unsigned. ('x'||hex)::bit(32)::int would sign-extend, and a
    -- negative draw here would index off the front of the array.
    v_bytes := gen_random_bytes(4);
    v_draw  := (get_byte(v_bytes, 0)::bigint << 24)
             | (get_byte(v_bytes, 1)::bigint << 16)
             | (get_byte(v_bytes, 2)::bigint <<  8)
             |  get_byte(v_bytes, 3)::bigint;

    EXIT WHEN v_draw < v_limit;

    IF v_tries >= 100 THEN
      -- Unreachable in practice. Taking the modulo anyway is better than
      -- looping forever inside the tick, and the bias it reintroduces is the
      -- one this function was already an improvement on.
      EXIT;
    END IF;
  END LOOP;

  RETURN (v_draw % p_upper)::integer + 1;
END;
$$;

COMMENT ON FUNCTION secure_random_int(integer) IS
  'Uniform integer in [1, n] from pgcrypto''s CSPRNG, by rejection sampling. The bingo draw uses this rather than random(), whose state is recoverable from the outputs this game publishes.';

-- Same reasoning as game_tick below: a player who can call the draw directly
-- learns nothing useful, but there is no reason for this to be reachable over
-- HTTP, and db/20-post/004's allowlist would revoke it on the next apply
-- regardless. Stating it here keeps the two files from disagreeing in between.
REVOKE ALL ON FUNCTION secure_random_int(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION secure_random_int(integer) TO service_role;

CREATE OR REPLACE FUNCTION game_tick(
  p_call_interval_ms   integer DEFAULT 3500,
  p_claim_window_ms    integer DEFAULT 1000,
  p_countdown_seconds  integer DEFAULT 25,
  p_selection_lead_ms  integer DEFAULT 5000,
  p_max_numbers        integer DEFAULT 75
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_game               RECORD;
  v_new_number         integer;
  v_remaining          integer[];
  v_numbers_called     integer := 0;
  v_games_started      integer := 0;
  v_games_finished     integer := 0;
  v_countdowns_rolled  integer := 0;
  v_claims_closed      integer := 0;
  v_game_created       boolean := false;
  v_player_count       integer;
  v_next_game_number   integer;
  v_new_game_id        uuid;
  v_oldest_call_age_ms integer := 0;
  v_keeper             uuid;
  v_surplus_closed     integer := 0;
BEGIN
  -- =========================================================================
  -- 1. Close expired claim windows
  --
  -- Runs BEFORE number calling so a game whose window has closed is finished
  -- rather than having another number called into it.
  --
  -- Setting status='finished' fires the payout_winners() trigger, which credits
  -- winners and sets winners_paid. That trigger is idempotent.
  -- =========================================================================
  FOR v_game IN
    SELECT id, claim_window_start
    FROM games
    WHERE status = 'playing'
      AND claim_window_start IS NOT NULL
      AND claim_window_start <= now() - make_interval(secs => p_claim_window_ms / 1000.0)
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE games
    SET status = 'finished',
        finished_at = now()
    WHERE id = v_game.id
      AND status = 'playing';

    v_claims_closed := v_claims_closed + 1;
    v_games_finished := v_games_finished + 1;
  END LOOP;

  -- =========================================================================
  -- 2. Call the next number
  --
  -- SKIP LOCKED rather than blocking: if another ticker somehow holds this row,
  -- the correct behaviour is to leave it alone this tick, not to queue up and
  -- call a number late.
  -- =========================================================================
  FOR v_game IN
    SELECT id, called_numbers, last_number_called_at
    FROM games
    WHERE status = 'playing'
      AND claim_window_start IS NULL
      AND (
        last_number_called_at IS NULL
        OR last_number_called_at <= now() - make_interval(secs => p_call_interval_ms / 1000.0)
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Exhausted the board: finish rather than spin.
    IF coalesce(array_length(v_game.called_numbers, 1), 0) >= p_max_numbers THEN
      UPDATE games
      SET status = 'finished',
          finished_at = now()
      WHERE id = v_game.id;

      v_games_finished := v_games_finished + 1;
      CONTINUE;
    END IF;

    v_remaining := ARRAY(
      SELECT n FROM generate_series(1, p_max_numbers) n
      WHERE n <> ALL(coalesce(v_game.called_numbers, ARRAY[]::integer[]))
    );

    IF coalesce(array_length(v_remaining, 1), 0) = 0 THEN
      UPDATE games
      SET status = 'finished',
          finished_at = now()
      WHERE id = v_game.id;

      v_games_finished := v_games_finished + 1;
      CONTINUE;
    END IF;

    -- The draw. See secure_random_int() below for why this is not random().
    v_new_number := v_remaining[secure_random_int(array_length(v_remaining, 1))];

    UPDATE games
    SET current_number = v_new_number,
        called_numbers = array_append(called_numbers, v_new_number),
        last_number_called_at = now()
    WHERE id = v_game.id;

    v_numbers_called := v_numbers_called + 1;
  END LOOP;

  -- =========================================================================
  -- 3. Start games whose countdown expired, or roll the countdown
  --
  -- A game with no players must not start: it would produce a zero-pot round
  -- and immediately finish. Rolling the countdown keeps the lobby alive without
  -- needing a browser to do it.
  -- =========================================================================
  FOR v_game IN
    SELECT id, starts_at
    FROM games
    WHERE status = 'waiting'
      AND starts_at <= now()
    FOR UPDATE SKIP LOCKED
  LOOP
    SELECT count(*) INTO v_player_count FROM players WHERE game_id = v_game.id;

    IF v_player_count > 0 THEN
      UPDATE games
      SET status = 'playing',
          started_at = now(),
          -- Seed so the first number is called on the NEXT tick rather than
          -- instantly, giving players the moment the countdown promised.
          last_number_called_at = now()
      WHERE id = v_game.id
        AND status = 'waiting';

      v_games_started := v_games_started + 1;
    ELSE
      UPDATE games
      SET starts_at = now() + make_interval(secs => p_countdown_seconds),
          selection_closed_at =
            now() + make_interval(secs => p_countdown_seconds)
                  - make_interval(secs => p_selection_lead_ms / 1000.0)
      WHERE id = v_game.id;

      v_countdowns_rolled := v_countdowns_rolled + 1;
    END IF;
  END LOOP;

  -- =========================================================================
  -- 4. Close surplus waiting games
  --
  -- Step 5 guarantees AT LEAST one waiting game. Nothing guaranteed AT MOST
  -- one, and the difference is not academic: dev has carried two since
  -- 2026-08-13, created days apart with duplicate game numbers (13 and 1, from
  -- two different numbering series). Neither ever starts, because neither has
  -- players and step 3 only starts a game that does; so the ticker rolls both
  -- countdowns forever and the lobby has a second game nobody can join.
  --
  -- The check-then-insert in step 5 is only serialised by the ticker's advisory
  -- lock. That is enough to stop the ticker racing ITSELF, and nothing else:
  -- create_next_game_after_finish() inserts on the finish trigger,
  -- ensure_waiting_game_exists() is still callable, and the browser-driven
  -- version this function replaced could do it too. A duplicate from any of
  -- those is permanent, because nothing ever removed one.
  --
  -- ONLY EMPTY GAMES ARE DELETED, and that guard is load-bearing rather than
  -- cautious. players.game_id is REFERENCES games(id) ON DELETE CASCADE, and a
  -- cascade performs a real DELETE on the child rows -- which fires
  -- refund_player_stake() BEFORE DELETE ON players. Deleting a waiting game
  -- that somebody had joined would therefore refund every player in it and
  -- rewrite balances. The keeper is chosen as the game WITH players when there
  -- is one, so the surviving lobby is the one people are actually sitting in.
  --
  -- DELETE RATHER THAN status='finished', which is the obvious alternative and
  -- is exactly wrong here: create_next_game_on_finish fires AFTER UPDATE when a
  -- game reaches 'finished' and inserts a new waiting game. Finishing a surplus
  -- game would create a replacement for it.
  --
  -- If two waiting games BOTH have players this deletes neither, deliberately.
  -- That is a state no automatic rule should resolve by discarding somebody's
  -- seat; it stays visible in waiting_games below.
  -- =========================================================================
  SELECT g.id INTO v_keeper
    FROM games g
   WHERE g.status = 'waiting'
   ORDER BY (EXISTS (SELECT 1 FROM players p WHERE p.game_id = g.id)) DESC,
            g.created_at ASC
   LIMIT 1;

  IF v_keeper IS NOT NULL THEN
    FOR v_game IN
      SELECT g.id
        FROM games g
       WHERE g.status = 'waiting'
         AND g.id <> v_keeper
         AND NOT EXISTS (SELECT 1 FROM players p WHERE p.game_id = g.id)
       FOR UPDATE SKIP LOCKED
    LOOP
      DELETE FROM games WHERE id = v_game.id;
      v_surplus_closed := v_surplus_closed + 1;
    END LOOP;
  END IF;

  -- =========================================================================
  -- 5. Ensure a waiting game exists
  --
  -- Previously done by whichever browser noticed first, via a non-atomic
  -- "check then insert" that let two clients create two games. Here the
  -- ticker's advisory lock already serialises it -- against itself. Step 4 is
  -- what handles a duplicate arriving from anywhere else.
  -- =========================================================================
  IF NOT EXISTS (SELECT 1 FROM games WHERE status = 'waiting') THEN
    SELECT coalesce(max(game_number), 0) + 1 INTO v_next_game_number FROM games;

    -- Column list mirrors ensure_waiting_game_exists(), which is the reliable
    -- reference for the CURRENT shape of this table. `code` was in the original
    -- CREATE TABLE but dropped by the second migration
    -- (20251109203630_update_bingo_auto_games), so reading the initial schema
    -- and stopping there gets you a column that has not existed for months.
    INSERT INTO games (
      status, host_id, called_numbers, game_number,
      starts_at, selection_closed_at, current_number, winner_ids,
      stake_amount, total_pot, winner_prize, winner_prize_each
    ) VALUES (
      'waiting',
      'system',
      ARRAY[]::integer[],
      v_next_game_number,
      now() + make_interval(secs => p_countdown_seconds),
      now() + make_interval(secs => p_countdown_seconds)
            - make_interval(secs => p_selection_lead_ms / 1000.0),
      NULL,
      ARRAY[]::uuid[],
      10, 0, 0, 0
    )
    RETURNING id INTO v_new_game_id;

    v_game_created := true;
  END IF;

  -- =========================================================================
  -- 6. Health signal
  --
  -- The age of the least-recently-called playing game. The ticker publishes
  -- this as SecondsSinceLastNumberCalled; an alarm on it is what turns a frozen
  -- game from a support ticket into a page.
  -- =========================================================================
  SELECT coalesce(
    max(extract(epoch FROM (now() - last_number_called_at)) * 1000)::integer, 0)
  INTO v_oldest_call_age_ms
  FROM games
  WHERE status = 'playing' AND last_number_called_at IS NOT NULL;

  RETURN jsonb_build_object(
    'numbers_called',       v_numbers_called,
    'games_started',        v_games_started,
    'games_finished',       v_games_finished,
    'countdowns_rolled',    v_countdowns_rolled,
    'claims_closed',        v_claims_closed,
    'waiting_game_created', v_game_created,
    'surplus_games_closed', v_surplus_closed,
    -- Published so "two lobbies, both with players" -- the one case step 4
    -- refuses to resolve on its own -- is visible rather than silent.
    'waiting_games', (SELECT count(*) FROM games WHERE status = 'waiting'),
    'oldest_call_age_ms',   v_oldest_call_age_ms,
    'active_games', (SELECT count(*) FROM games WHERE status = 'playing')
  );
END;
$$;

COMMENT ON FUNCTION game_tick(integer, integer, integer, integer, integer) IS
  'Server-authoritative game loop, called once per second by the ticker container while it holds the advisory lock. Replaces the browser-driven state machine and the unschedulable 4-second pg_cron job.';

-- Only privileged server-side code may drive the game. Explicitly revoked from
-- anon and authenticated: a player being able to call the next number early
-- would be a straightforward way to cheat.
--
-- ARGUMENT TYPES NAMED, not the bare name. `ON FUNCTION game_tick` resolves only
-- while exactly one signature exists, and fails the whole migration the moment a
-- second one does:
--
--   ERROR: function name "game_tick" is not unique
--
-- scripts/check-migrations.mjs exists because that has happened three times
-- here, and its header records that a failing GRANT is how the first one was
-- found -- against the real database, after passing every local check. There is
-- no reason to keep relying on uniqueness when stating the types costs nothing.
-- Matches how 013, 015 and 016 already write theirs.
REVOKE ALL ON FUNCTION game_tick(integer, integer, integer, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION game_tick(integer, integer, integer, integer, integer)
  TO service_role;
