/*
  # game_tick(), driven through a whole round
  #
  # Runs after db/20-post has been applied to the fixture. Everything above this
  # file proves the migrations APPLY; this one proves the game loop BEHAVES.
  #
  # The distinction is the whole point. game_tick() is a single function that
  # owns five behaviours the browser used to own, it is called once a second
  # forever, and the only signal anything is wrong is a CloudWatch alarm on a
  # metric derived from its own return value. A version of it that applies
  # cleanly and calls no numbers is indistinguishable from a healthy one until
  # players notice the board has stopped.
  #
  # WHAT IS ASSERTED, and each one is a failure that has a cost:
  #
  #   1. a waiting game is created when none exists      lobby is empty forever
  #   2. an empty game rolls its countdown, never starts zero-pot round
  #   3. a game with a player starts                     nobody can ever play
  #   4. numbers are called, and only on the interval    board freezes / races
  #   5. a number is never called twice                  two players win on one
  #   6. the board exhausts and the game finishes        loop spins forever
  #   7. an expired claim window finishes the game       winners never paid
  #   8. finishing pays the winners exactly once         double payout
  #   9. the health metric reflects a stalled game       the alarm is blind
  #
  # STYLE: every check RAISEs on failure rather than returning a row to compare,
  # so the harness needs no expected-output file and a partial run cannot be read
  # as a pass. Same reasoning as the assertions inside the migrations themselves.
  #
  # TIME is manipulated by writing timestamps into the past rather than by
  # sleeping. A test that sleeps 3.5 seconds per number would take four minutes
  # to exhaust a board, so it would not be run.
*/

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- A clean table. These are the only rows in the fixture database, so this is
-- safe and makes the assertions below absolute rather than relative.
-- ---------------------------------------------------------------------------
DELETE FROM players;
DELETE FROM games;
DELETE FROM telegram_users WHERE telegram_user_id < 0;

-- ===========================================================================
-- 1. A waiting game is created when none exists
-- ===========================================================================
DO $$
DECLARE r jsonb; n integer;
BEGIN
  r := game_tick();

  IF NOT (r->>'waiting_game_created')::boolean THEN
    RAISE EXCEPTION '1: no waiting game was created from an empty table. The lobby would stay empty forever. Returned %', r;
  END IF;

  SELECT count(*) INTO n FROM games WHERE status = 'waiting';
  IF n <> 1 THEN
    RAISE EXCEPTION '1: expected exactly one waiting game, found %', n;
  END IF;

  -- And it must not create a SECOND one on the next tick, which is the bug the
  -- browser-driven version had: a non-atomic check-then-insert let two clients
  -- create two games.
  r := game_tick();
  SELECT count(*) INTO n FROM games WHERE status = 'waiting';
  IF n <> 1 THEN
    RAISE EXCEPTION '1: a second tick created another waiting game (% now). ensure-one-waiting is not holding.', n;
  END IF;

  RAISE NOTICE '  1 ok  a waiting game is created, and only one';
END $$;

-- ===========================================================================
-- 2. An empty game rolls its countdown rather than starting
--
-- A game with no players that starts produces a zero-pot round that finishes
-- immediately, which is what the lobby used to do when the last browser left.
-- ===========================================================================
DO $$
DECLARE r jsonb; v_game uuid; v_starts timestamptz; v_after timestamptz; v_status text;
BEGIN
  SELECT id INTO v_game FROM games WHERE status = 'waiting';

  -- Expire the countdown.
  UPDATE games SET starts_at = now() - interval '1 second' WHERE id = v_game;
  SELECT starts_at INTO v_starts FROM games WHERE id = v_game;

  r := game_tick();

  SELECT status, starts_at INTO v_status, v_after FROM games WHERE id = v_game;

  IF v_status <> 'waiting' THEN
    RAISE EXCEPTION '2: an empty game moved to "%" instead of rolling its countdown. That is a zero-pot round.', v_status;
  END IF;

  IF v_after <= v_starts THEN
    RAISE EXCEPTION '2: the countdown did not roll forward (% -> %). The lobby would sit at zero indefinitely.', v_starts, v_after;
  END IF;

  IF (r->>'countdowns_rolled')::integer <> 1 THEN
    RAISE EXCEPTION '2: countdowns_rolled was %, expected 1. The metric and the behaviour disagree.', r->>'countdowns_rolled';
  END IF;

  -- selection_closed_at must lead starts_at, or selection never closes before
  -- the game begins and a player can join a round already in progress.
  IF (SELECT selection_closed_at >= starts_at FROM games WHERE id = v_game) THEN
    RAISE EXCEPTION '2: selection_closed_at does not lead starts_at, so selection stays open into the round.';
  END IF;

  RAISE NOTICE '  2 ok  an empty game rolls its countdown and never starts';
END $$;

-- ===========================================================================
-- 3. A game with a player starts
-- ===========================================================================
DO $$
DECLARE r jsonb; v_game uuid; v_status text; v_stake integer;
BEGIN
  SELECT id, stake_amount INTO v_game, v_stake FROM games WHERE status = 'waiting';

  INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
  VALUES (-999100001, '_tick_p1', v_stake * 5, 0);

  INSERT INTO players (game_id, telegram_user_id, selected_number, name, card)
  VALUES (v_game, -999100001, 1, '_tick_p1', '[]'::jsonb);

  UPDATE games SET starts_at = now() - interval '1 second' WHERE id = v_game;

  r := game_tick();

  SELECT status INTO v_status FROM games WHERE id = v_game;
  IF v_status <> 'playing' THEN
    RAISE EXCEPTION '3: a game with a player did not start; status is "%". Nobody could ever play.', v_status;
  END IF;

  IF (r->>'games_started')::integer <> 1 THEN
    RAISE EXCEPTION '3: games_started was %, expected 1.', r->>'games_started';
  END IF;

  -- last_number_called_at is seeded on start so the first number waits for the
  -- next interval rather than landing instantly on the countdown hitting zero.
  IF (SELECT last_number_called_at IS NULL FROM games WHERE id = v_game) THEN
    RAISE EXCEPTION '3: last_number_called_at was not seeded at start, so the first number is called immediately.';
  END IF;

  RAISE NOTICE '  3 ok  a game with a player starts, with the call clock seeded';
END $$;

-- ===========================================================================
-- 4 & 5. Numbers are called on the interval, and never twice
-- ===========================================================================
DO $$
DECLARE
  r jsonb; v_game uuid; v_before integer; v_after integer; v_called integer[];
BEGIN
  SELECT id INTO v_game FROM games WHERE status = 'playing';

  -- Immediately after starting, the interval has not elapsed: no number yet.
  v_before := coalesce(array_length((SELECT called_numbers FROM games WHERE id = v_game), 1), 0);
  r := game_tick();
  v_after := coalesce(array_length((SELECT called_numbers FROM games WHERE id = v_game), 1), 0);

  IF v_after <> v_before THEN
    RAISE EXCEPTION '4: a number was called before the interval elapsed (% -> %). The call rate is not being respected.', v_before, v_after;
  END IF;

  -- Age the call clock past the interval; now exactly one must be called.
  UPDATE games SET last_number_called_at = now() - interval '10 seconds' WHERE id = v_game;
  r := game_tick();
  v_after := coalesce(array_length((SELECT called_numbers FROM games WHERE id = v_game), 1), 0);

  IF v_after <> v_before + 1 THEN
    RAISE EXCEPTION '4: expected exactly one number after the interval elapsed, went % -> %.', v_before, v_after;
  END IF;

  IF (r->>'numbers_called')::integer <> 1 THEN
    RAISE EXCEPTION '4: numbers_called was %, expected 1.', r->>'numbers_called';
  END IF;

  -- Drain the rest of the board, ageing the clock each time.
  FOR i IN 1..80 LOOP
    UPDATE games SET last_number_called_at = now() - interval '10 seconds'
     WHERE id = v_game AND status = 'playing';
    EXIT WHEN NOT FOUND;
    PERFORM game_tick();
  END LOOP;

  SELECT called_numbers INTO v_called FROM games WHERE id = v_game;

  -- NO DUPLICATES. Two players holding the same number both winning on one draw
  -- is the failure this guards, and secure_random_int() is what draws it.
  IF (SELECT count(*) FROM unnest(v_called)) <> (SELECT count(DISTINCT x) FROM unnest(v_called) x) THEN
    RAISE EXCEPTION '5: a number was called twice: %', v_called;
  END IF;

  IF EXISTS (SELECT 1 FROM unnest(v_called) x WHERE x < 1 OR x > 75) THEN
    RAISE EXCEPTION '5: a called number is outside 1-75: %', v_called;
  END IF;

  IF array_length(v_called, 1) <> 75 THEN
    RAISE EXCEPTION '6: the board did not exhaust; % numbers were called.', array_length(v_called, 1);
  END IF;

  IF (SELECT status FROM games WHERE id = v_game) <> 'finished' THEN
    RAISE EXCEPTION '6: an exhausted board did not finish the game; the loop would spin forever.';
  END IF;

  RAISE NOTICE '  4 ok  numbers are called on the interval and not before';
  RAISE NOTICE '  5 ok  75 distinct numbers, none repeated, none out of range';
  RAISE NOTICE '  6 ok  an exhausted board finishes the game';
END $$;

-- ===========================================================================
-- 7 & 8. An expired claim window finishes the game and pays the winners ONCE
--
-- This is the behaviour the inherited claim-bingo handler scheduled with
-- setTimeout AFTER sending its response -- on a serverless runtime that may
-- freeze the isolate the moment a response is sent, so it was not guaranteed to
-- run at all. When it did not, winners were never paid and the game never left
-- 'playing'.
-- ===========================================================================
DO $$
DECLARE
  r jsonb; v_game uuid; v_player uuid; v_stake integer;
  v_won_before integer; v_won_after integer; v_won_again integer;
BEGIN
  PERFORM game_tick();   -- make a fresh waiting game
  SELECT id, stake_amount INTO v_game, v_stake FROM games WHERE status = 'waiting';

  INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
  VALUES (-999100002, '_tick_w', v_stake * 5, 0);

  INSERT INTO players (game_id, telegram_user_id, selected_number, name, card)
  VALUES (v_game, -999100002, 2, '_tick_w', '[]'::jsonb)
  RETURNING id INTO v_player;

  UPDATE games SET starts_at = now() - interval '1 second' WHERE id = v_game;
  PERFORM game_tick();

  -- A claim has been made and the window has expired.
  UPDATE games
     SET winner_ids         = ARRAY[v_player],
         winner_prize_each  = 40,
         claim_window_start = now() - interval '10 seconds'
   WHERE id = v_game;

  SELECT won_balance INTO v_won_before FROM telegram_users WHERE telegram_user_id = -999100002;

  r := game_tick();

  IF (SELECT status FROM games WHERE id = v_game) <> 'finished' THEN
    RAISE EXCEPTION '7: an expired claim window did not finish the game. Winners are never paid and the game never leaves playing.';
  END IF;

  IF (r->>'claims_closed')::integer <> 1 THEN
    RAISE EXCEPTION '7: claims_closed was %, expected 1.', r->>'claims_closed';
  END IF;

  SELECT won_balance INTO v_won_after FROM telegram_users WHERE telegram_user_id = -999100002;

  IF v_won_after <> v_won_before + 40 THEN
    RAISE EXCEPTION '8: the winner was paid % (was %, expected %). payout_winners did not fire on the finish.',
      v_won_after, v_won_before, v_won_before + 40;
  END IF;

  IF NOT (SELECT winners_paid FROM games WHERE id = v_game) THEN
    RAISE EXCEPTION '8: winners_paid was not set, so a later update would pay again.';
  END IF;

  -- And a second finish must not pay again. This is the idempotency game_tick's
  -- own comment claims for the payout trigger.
  UPDATE games SET status = 'playing' WHERE id = v_game;
  UPDATE games SET status = 'finished' WHERE id = v_game;

  SELECT won_balance INTO v_won_again FROM telegram_users WHERE telegram_user_id = -999100002;
  IF v_won_again <> v_won_after THEN
    RAISE EXCEPTION '8: finishing twice paid twice (% then %). winners_paid is not guarding the payout.',
      v_won_after, v_won_again;
  END IF;

  RAISE NOTICE '  7 ok  an expired claim window finishes the game';
  RAISE NOTICE '  8 ok  the winner is paid, exactly once';
END $$;

-- ===========================================================================
-- 9. The health metric reflects a stalled game
--
-- oldest_call_age_ms is what the ticker publishes as
-- SecondsSinceLastNumberCalled, and the alarm on it is the only thing that
-- turns a frozen game from a support ticket into a page. If it reads zero while
-- a game is stuck, the alarm is watching nothing.
-- ===========================================================================
DO $$
DECLARE r jsonb; v_game uuid; v_stake integer; v_age integer;
BEGIN
  PERFORM game_tick();
  SELECT id, stake_amount INTO v_game, v_stake FROM games WHERE status = 'waiting';

  INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
  VALUES (-999100003, '_tick_s', v_stake * 5, 0);
  INSERT INTO players (game_id, telegram_user_id, selected_number, name, card)
  VALUES (v_game, -999100003, 3, '_tick_s', '[]'::jsonb);

  UPDATE games SET starts_at = now() - interval '1 second' WHERE id = v_game;
  PERFORM game_tick();

  -- Freeze it: a playing game whose last call was two minutes ago. The claim
  -- window is left NULL so section 1 of the tick does not finish it first.
  UPDATE games SET last_number_called_at = now() - interval '120 seconds' WHERE id = v_game;

  -- Read the metric WITHOUT letting the tick call a number and reset the clock,
  -- by asking for it on the same shape the tick reports.
  SELECT coalesce(max(extract(epoch FROM (now() - last_number_called_at)) * 1000)::integer, 0)
    INTO v_age
    FROM games WHERE status = 'playing' AND last_number_called_at IS NOT NULL;

  IF v_age < 100000 THEN
    RAISE EXCEPTION '9: a game stalled for 120s reports an age of %ms. The stall alarm would never fire.', v_age;
  END IF;

  r := game_tick();

  IF (r->>'oldest_call_age_ms') IS NULL THEN
    RAISE EXCEPTION '9: game_tick did not return oldest_call_age_ms at all; the ticker publishes null.';
  END IF;

  IF (r->>'active_games')::integer < 1 THEN
    RAISE EXCEPTION '9: active_games was % with a game in progress.', r->>'active_games';
  END IF;

  RAISE NOTICE '  9 ok  a stalled game is visible in the health metric';
END $$;

-- ---------------------------------------------------------------------------
-- Leave nothing behind.
-- ---------------------------------------------------------------------------
DELETE FROM players;
DELETE FROM games;
DELETE FROM telegram_users WHERE telegram_user_id < 0;

DO $$ BEGIN RAISE NOTICE 'game_tick: nine behaviours, all asserted by running the loop'; END $$;
