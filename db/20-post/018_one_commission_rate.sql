/*
  # update_game_pot(): the other half of the pot arithmetic
  #
  # db/20-post/013 introduced commission_rate() and explains the defect in full.
  # 014's refund path now calls it. This is the join path, which is the one that
  # produced the silent failure:
  #
  #   settings row missing -> commission_rate_val NULL (the COALESCE is INSIDE
  #                           the query, so it never runs on zero rows)
  #                        -> winner_prize = FLOOR(pot * (100 - NULL) / 100)
  #                        -> NULL
  #                        -> atomic_claim_bingo pays
  #                           FLOOR(COALESCE(winner_prize, 0) / n) = 0
  #
  # A finished game, winners_paid set, every winner paid nothing, and no error
  # anywhere. refund_player_stake() at least had an `IF ... IS NULL` after its
  # read; this one has nothing.
  #
  # THE search_path LINE IS NOT COPIED FROM THE OTHERS BY HABIT.
  #
  # db/20-post/017 pins search_path on every SECURITY DEFINER function, and this
  # one is deliberately NOT security definer -- it is a trigger that should act
  # with the privileges of whoever is inserting. That normally makes shadowing a
  # non-issue: a caller who shadows a table in their own session only fools
  # themselves, since they could write to their own table directly anyway.
  #
  # It is an issue HERE because of who actually fires it. Players rows are
  # inserted by select_card_atomic(), which IS security definer, so this trigger
  # runs as the function's OWNER while the SESSION -- and therefore pg_temp --
  # still belongs to the caller. An unpinned search_path in that position means a
  # caller's temp `games` table receives the pot update instead of the real one.
  # So it gets pinned, without becoming a definer function.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- ---------------------------------------------------------------------------
-- 1. Establish the invariant commission_rate() now depends on
--
-- 20251225110557 inserts this row and 20251227071701 sets it to 20, so on any
-- database built from the full history it is already here. This is for the ones
-- that are not: a restore from a partial dump, or a row somebody removed by
-- hand. commission_rate() refuses to guess, which turns a missing row from a
-- silent zero payout into a failed join -- and this is what stops that failed
-- join from being how anybody finds out.
--
-- ON CONFLICT DO NOTHING: never overwrite an operator's chosen rate.
-- ---------------------------------------------------------------------------
INSERT INTO settings (id, value, description, updated_at, updated_by)
VALUES (
  'commission_rate',
  '20',
  'Percentage of game pot taken as house commission (0-100)',
  now(),
  'system'
)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. One reader
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_game_pot()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rate integer;
BEGIN
  -- Raises if the setting is absent or out of range. Deliberately not caught:
  -- a pot built on an assumed house cut is the failure this replaces.
  v_rate := commission_rate();

  UPDATE games
  SET
    total_pot    = total_pot + stake_amount,
    winner_prize = FLOOR((total_pot + stake_amount) * (100 - v_rate) / 100)
  WHERE id = NEW.game_id;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION update_game_pot() IS
  'Trigger (AFTER INSERT ON players): adds the stake to the pot and recomputes winner_prize at commission_rate(). Shares that reader with refund_player_stake() so a pot cannot be built at one rate and rebuilt at another.';

-- ---------------------------------------------------------------------------
-- 3. Assert it, BY RUNNING BOTH TRIGGERS
--
-- Same discipline as 014: not by reading the two bodies, which would prove only
-- that the same call appears twice. A real player joins a real waiting game and
-- is then released, and the assertion is that winner_prize agrees with the SAME
-- rate at both ends -- which is precisely what was untrue before.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tg      bigint := -999000002;   -- negative, cannot collide with a Telegram id
  v_game    uuid;
  v_stake   integer;
  v_player  uuid;
  v_rate    integer;
  v_pot0    integer;
  v_pot1    integer;
  v_pot2    integer;
  v_prize1  integer;
  v_prize2  integer;
  v_raised  boolean;
BEGIN
  v_rate := commission_rate();

  SELECT id, stake_amount, total_pot INTO v_game, v_stake, v_pot0
    FROM games WHERE status = 'waiting' LIMIT 1;

  IF v_game IS NULL AND EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'ensure_waiting_game_exists'
  ) THEN
    PERFORM ensure_waiting_game_exists();
    SELECT id, stake_amount, total_pot INTO v_game, v_stake, v_pot0
      FROM games WHERE status = 'waiting' LIMIT 1;
  END IF;

  -- RAISE, DO NOT SKIP. 014 documents why at length: a probe that returns
  -- quietly when it cannot build its case reports success for a control it
  -- never executed.
  IF v_game IS NULL THEN
    RAISE EXCEPTION
      'cannot verify the pot rate: no waiting game exists and ensure_waiting_game_exists() is unavailable. Run SELECT game_tick(); and re-apply.';
  END IF;

  -- Enough balance that the deduct trigger cannot refuse the join for an
  -- unrelated reason and leave this proving nothing.
  INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
  VALUES (v_tg, '_rate_probe', v_stake * 10 + 1000, 0)
  ON CONFLICT (telegram_user_id) DO UPDATE
    SET deposited_balance = v_stake * 10 + 1000, won_balance = 0;

  INSERT INTO players (game_id, telegram_user_id, selected_number, name, card)
  VALUES (v_game, v_tg, 9998, '_rate_probe', '[]'::jsonb)
  RETURNING id INTO v_player;

  SELECT total_pot, winner_prize INTO v_pot1, v_prize1 FROM games WHERE id = v_game;

  DELETE FROM players WHERE id = v_player;

  SELECT total_pot, winner_prize INTO v_pot2, v_prize2 FROM games WHERE id = v_game;

  DELETE FROM telegram_users WHERE telegram_user_id = v_tg;

  -- The join built the pot.
  IF v_pot1 <> v_pot0 + v_stake THEN
    RAISE EXCEPTION
      'the join did not add the stake to the pot: % -> % for a stake of %. update_pot_on_player_join is not installed, so this file proved nothing.',
      v_pot0, v_pot1, v_stake;
  END IF;

  IF v_prize1 IS NULL THEN
    RAISE EXCEPTION
      'winner_prize is NULL after a join. This is the exact failure db/20-post/013 describes: atomic_claim_bingo would pay every winner zero.';
  END IF;

  IF v_prize1 <> FLOOR(v_pot1 * (100 - v_rate) / 100) THEN
    RAISE EXCEPTION
      'the join computed winner_prize % on a pot of %, but commission_rate() is % percent, which gives %.',
      v_prize1, v_pot1, v_rate, FLOOR(v_pot1 * (100 - v_rate) / 100);
  END IF;

  -- The release rebuilt it, AT THE SAME RATE. This is the assertion that would
  -- have failed before: 20 on the way in, 25 on the way out.
  IF v_pot2 <> v_pot0 THEN
    RAISE EXCEPTION
      'the release did not return the pot to where it started: % -> % -> %.',
      v_pot0, v_pot1, v_pot2;
  END IF;

  IF v_prize2 <> FLOOR(v_pot2 * (100 - v_rate) / 100) THEN
    RAISE EXCEPTION
      'join and release disagree about the house cut: releasing rebuilt winner_prize as % on a pot of %, but commission_rate() is % percent, which gives %.',
      v_prize2, v_pot2, v_rate, FLOOR(v_pot2 * (100 - v_rate) / 100);
  END IF;

  -- ---------------------------------------------------------------------
  -- And prove the refusal is real, because "it raises" is the whole design.
  --
  -- The DELETE runs inside a subtransaction that is ALWAYS rolled back: either
  -- commission_rate() raises and the inner handler catches it, or it does not
  -- and the explicit RAISE below unwinds the block regardless. PL/pgSQL
  -- variables are not transactional, so v_raised survives the rollback that
  -- restores the row.
  -- ---------------------------------------------------------------------
  BEGIN
    DELETE FROM settings WHERE id = 'commission_rate';

    BEGIN
      PERFORM commission_rate();
      v_raised := false;
    EXCEPTION WHEN others THEN
      v_raised := true;
    END;

    RAISE EXCEPTION 'rate_probe_rollback';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'rate_probe_rollback' THEN
      RAISE;
    END IF;
  END;

  IF NOT EXISTS (SELECT 1 FROM settings WHERE id = 'commission_rate') THEN
    RAISE EXCEPTION
      'the refusal probe did not restore settings.commission_rate. Do not leave this database in that state -- reinsert it before doing anything else.';
  END IF;

  IF NOT v_raised THEN
    RAISE EXCEPTION
      'commission_rate() returned a value with settings.commission_rate deleted. It is supposed to refuse; defaulting is what paid winners zero.';
  END IF;

  RAISE NOTICE 'pot rate: join and release agree at % percent, and a missing setting refuses instead of paying zero', v_rate;
END $$;
