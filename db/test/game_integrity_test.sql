/*
  # Can a player manufacture a win?
  #
  # Everything else in this harness asks whether the game WORKS. This asks
  # whether it can be CHEATED, which is a different question and the one that
  # decides whether a real-money game is fit to run.
  #
  # The threat model is a player who controls their own client completely: they
  # can edit any value the browser sends, replay requests, call the API directly
  # with their own token, and read every byte the server sends them. They cannot
  # forge a Telegram signature, and they cannot reach the database except through
  # the routes.
  #
  # WHAT THE SERVER MUST NOT TRUST, and each of these is a real attack rather
  # than a hypothetical -- every one was reachable in the inherited code:
  #
  #   the card       select_card_atomic took p_card_numbers from the REQUEST, so
  #                  a crafted join could arrive with a card made entirely of
  #                  numbers already called. services/functions/src/select-card.js
  #                  now derives it server-side from the card NUMBER.
  #   the marks      marked_cells is client state. If the win check consulted it,
  #                  tapping five cells would be a win.
  #   the identity   atomic_claim_bingo takes a players ROW id, so the token
  #                  saying who you are is not sufficient -- the row must be
  #                  yours. claim-bingo.js checks it.
  #   the outcome    games.winner_ids and winner_prize_each decide the payout,
  #                  and db/20-post/008 revoked the client's UPDATE on `games`
  #                  because setting them was a way to pay yourself.
  #
  # These assertions run the REAL check_player_win and atomic_claim_bingo, which
  # db/test/fixture.sql now carries verbatim rather than stubbing. Against a stub
  # every attack below "passes", which is exactly why the stub was replaced.
  #
  # WHERE THE RANDOMNESS IS TESTED: db/20-post/002 draws with secure_random_int(),
  # and db/test/game_tick_test.sql asserts 75 distinct numbers with no repeat. The
  # property that matters for cheating is that a player cannot PREDICT the next
  # draw, which rests on pgcrypto's CSPRNG rather than on anything assertable here.
*/

\set ON_ERROR_STOP on

DELETE FROM players;
DELETE FROM games;
DELETE FROM telegram_users WHERE telegram_user_id < 0;

-- ---------------------------------------------------------------------------
-- A game, a player, and a card we control precisely.
--
-- The card is written directly rather than dealt, because these tests are about
-- what the CHECK does with a given card -- not about how cards are assigned.
-- Column 2 row 2 is the free centre, stored as 0.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _t_setup(p_called integer[], p_current integer)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_game uuid; v_player uuid;
BEGIN
  DELETE FROM players; DELETE FROM games;
  DELETE FROM telegram_users WHERE telegram_user_id < 0;

  INSERT INTO games (status, host_id, game_number, called_numbers, current_number,
                     stake_amount, total_pot, winner_prize, winner_ids, winner_prize_each,
                     starts_at, started_at)
  VALUES ('playing', 'system', 500, p_called, p_current, 10, 100, 80,
          ARRAY[]::uuid[], 0, now(), now())
  RETURNING id INTO v_game;

  INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
  VALUES (-999200001, '_cheat', 500, 0);

  -- ROW 0 of this card is [1, 16, 31, 46, 61] -- card_numbers->col->>row, so one
  -- number from each column. The free centre is at [2][2], which is in ROW 2,
  -- not row 0; forgetting that is how the first draft of this file "proved" a
  -- genuine win was refused.
  INSERT INTO players (game_id, telegram_user_id, selected_number, name, card, card_numbers, marked_cells)
  VALUES (v_game, -999200001, 1, '_cheat', '[]'::jsonb,
          '[[1,2,3,4,5],[16,17,18,19,20],[31,32,0,34,35],[46,47,48,49,50],[61,62,63,64,65]]'::jsonb,
          '[[false,false,false,false,false],[false,false,false,false,false],[false,false,false,false,false],[false,false,false,false,false],[false,false,false,false,false]]'::jsonb)
  RETURNING id INTO v_player;

  RETURN v_player;
END $$;

-- ===========================================================================
-- 1. MARKING CELLS YOU WERE NOT DEALT IS WORTH NOTHING
--
-- The attack: set every cell in marked_cells to true and claim. On a client
-- that decides wins, this is an instant, unfalsifiable victory.
-- ===========================================================================
DO $$
DECLARE v_player uuid; r jsonb;
BEGIN
  -- Only ONE of the first row's numbers has been called, so no line exists.
  v_player := _t_setup(ARRAY[1], 1);

  UPDATE players SET marked_cells =
    '[[true,true,true,true,true],[true,true,true,true,true],[true,true,true,true,true],[true,true,true,true,true],[true,true,true,true,true]]'::jsonb
   WHERE id = v_player;

  r := atomic_claim_bingo(v_player);

  IF (r->>'isWinner')::boolean IS TRUE THEN
    RAISE EXCEPTION '1: a fully-marked card won with one number called. marked_cells is client state; the win check must ignore it entirely. Result: %', r;
  END IF;

  RAISE NOTICE '  1 ok  a fully-marked card wins nothing; marks are not consulted';
END $$;

-- ===========================================================================
-- 2. A WIN NEEDS THE NUMBERS TO HAVE BEEN CALLED
--
-- The honest case, to prove the check is not simply refusing everything: the
-- same card, with the whole first row called, and the last of them current.
-- ===========================================================================
DO $$
DECLARE v_player uuid; r jsonb;
BEGIN
  v_player := _t_setup(ARRAY[1,16,31,46,61], 61);
  r := atomic_claim_bingo(v_player);

  IF (r->>'isWinner')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION '2: a genuine line was REFUSED, so tests 1 and 3 prove nothing -- a check that refuses everything is not a check. Result: %', r;
  END IF;

  RAISE NOTICE '  2 ok  a genuine completed line is accepted (so the refusals mean something)';
END $$;

-- ===========================================================================
-- 3. THE CLAIM MUST BE COMPLETED BY THE CURRENT NUMBER
--
-- Bingo's actual rule, and a real anti-cheat: you claim on the draw that
-- completes your card. Without it a player could sit on a completed line and
-- claim at a moment of their choosing -- which matters because the claim window
-- decides who SHARES the pot.
-- ===========================================================================
DO $$
DECLARE v_player uuid; r jsonb;
BEGIN
  -- The whole first row is called, but the CURRENT number is 2 -- a number on
  -- the card that is not part of the completed line. The line was completed two
  -- draws ago.
  v_player := _t_setup(ARRAY[1,16,31,46,61,2], 2);
  r := atomic_claim_bingo(v_player);

  IF (r->>'isWinner')::boolean IS TRUE THEN
    RAISE EXCEPTION '3: a stale line was claimable. A player could hold a completed card and choose WHEN to claim, which decides who shares the pot. Result: %', r;
  END IF;

  RAISE NOTICE '  3 ok  a line completed by an earlier draw cannot be claimed later';
END $$;

-- ===========================================================================
-- 4. A NUMBER THAT WAS NEVER DRAWN CANNOT COMPLETE A LINE
--
-- The attack: claim while naming a current_number that is not in called_numbers.
-- A player cannot set current_number over HTTP -- 008 revoked UPDATE on games --
-- but the check refuses it independently, which is the belt to that braces.
-- ===========================================================================
DO $$
DECLARE v_player uuid; r jsonb;
BEGIN
  v_player := _t_setup(ARRAY[1,16,31,46], 61);   -- 61 is CURRENT but never called
  r := atomic_claim_bingo(v_player);

  IF (r->>'isWinner')::boolean IS TRUE THEN
    RAISE EXCEPTION '4: a line completed by an undrawn number was accepted. Result: %', r;
  END IF;

  RAISE NOTICE '  4 ok  an undrawn current number cannot complete a line';
END $$;

-- ===========================================================================
-- 5. A DISQUALIFIED PLAYER CANNOT CLAIM
-- ===========================================================================
DO $$
DECLARE v_player uuid; r jsonb;
BEGIN
  v_player := _t_setup(ARRAY[1,16,31,46,61], 61);
  UPDATE players SET is_disqualified = true WHERE id = v_player;

  r := atomic_claim_bingo(v_player);

  IF (r->>'isWinner')::boolean IS TRUE THEN
    RAISE EXCEPTION '5: a disqualified player claimed a win. Result: %', r;
  END IF;

  RAISE NOTICE '  5 ok  a disqualified player cannot claim';
END $$;

-- ===========================================================================
-- 6. CLAIMING TWICE DOES NOT WIN TWICE
--
-- The same winning claim, replayed. A client retrying on a flaky mobile network
-- does this by accident, so it is a correctness requirement before it is a
-- security one.
-- ===========================================================================
DO $$
DECLARE v_player uuid; r1 jsonb; r2 jsonb; v_ids uuid[];
BEGIN
  v_player := _t_setup(ARRAY[1,16,31,46,61], 61);
  r1 := atomic_claim_bingo(v_player);
  r2 := atomic_claim_bingo(v_player);

  IF (r2->>'alreadyClaimed')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION '6: the second claim was not recognised as a replay. Result: %', r2;
  END IF;

  SELECT winner_ids INTO v_ids FROM games WHERE status IN ('playing','finished') LIMIT 1;
  IF array_length(v_ids, 1) <> 1 THEN
    RAISE EXCEPTION '6: replaying a claim put the player in winner_ids % times. The pot is split by that array length, so a replay would dilute every other winner.',
      array_length(v_ids, 1);
  END IF;

  RAISE NOTICE '  6 ok  a replayed claim wins once and does not dilute the split';
END $$;

-- ===========================================================================
-- 7. THE ROUTES THE CLIENT CAN REACH CANNOT DECIDE A WIN
--
-- The database half of the argument. Everything above is the win CHECK; this is
-- whether a player can go around it. `authenticated` is the role a player's JWT
-- resolves to through PostgREST.
-- ===========================================================================
DO $$
DECLARE v_bad text := '';
BEGIN
  IF has_function_privilege('authenticated', 'atomic_claim_bingo(uuid,integer)', 'EXECUTE') THEN
    v_bad := v_bad || 'atomic_claim_bingo is EXECUTE-able by authenticated -- a player could claim for any player row, bypassing the ownership check in claim-bingo.js. ';
  END IF;

  IF has_function_privilege('authenticated', 'game_tick(integer,integer,integer,integer,integer)', 'EXECUTE') THEN
    v_bad := v_bad || 'game_tick is EXECUTE-able by authenticated -- a player could call the next number on demand. ';
  END IF;

  IF has_function_privilege('authenticated', 'secure_random_int(integer)', 'EXECUTE') THEN
    v_bad := v_bad || 'secure_random_int is EXECUTE-able by authenticated. ';
  END IF;

  IF has_table_privilege('authenticated', 'games', 'UPDATE') THEN
    v_bad := v_bad || 'authenticated can UPDATE games -- winner_ids and winner_prize_each are columns on it, so a player could pay themselves. ';
  END IF;

  IF has_table_privilege('authenticated', 'players', 'UPDATE') THEN
    v_bad := v_bad || 'authenticated can UPDATE players -- card_numbers is a column on it, so a player could rewrite their own card. ';
  END IF;

  IF has_table_privilege('authenticated', 'players', 'DELETE') THEN
    v_bad := v_bad || 'authenticated can DELETE players -- that fires refund_player_stake, so a player could refund themselves out of a losing game. ';
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION '7: %', v_bad;
  END IF;

  RAISE NOTICE '  7 ok  a player cannot call the win logic or write the tables it reads';
END $$;

-- ===========================================================================
-- 8. NOR CAN AN UNAUTHENTICATED CALLER
-- ===========================================================================
DO $$
DECLARE v_bad text := '';
BEGIN
  IF has_function_privilege('anon', 'atomic_claim_bingo(uuid,integer)', 'EXECUTE') THEN
    v_bad := v_bad || 'anon can claim. ';
  END IF;
  IF has_table_privilege('anon', 'games', 'UPDATE') THEN
    v_bad := v_bad || 'anon can UPDATE games. ';
  END IF;
  IF has_table_privilege('anon', 'players', 'INSERT') THEN
    v_bad := v_bad || 'anon can INSERT players -- joining a game without paying. ';
  END IF;

  IF v_bad <> '' THEN
    RAISE EXCEPTION '8: %', v_bad;
  END IF;

  RAISE NOTICE '  8 ok  an unauthenticated caller can do none of it either';
END $$;

DROP FUNCTION _t_setup(integer[], integer);
DELETE FROM players;
DELETE FROM games;
DELETE FROM telegram_users WHERE telegram_user_id < 0;

DO $$ BEGIN RAISE NOTICE 'game integrity: eight attacks, all refused'; END $$;
