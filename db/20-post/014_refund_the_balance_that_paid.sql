/*
  # Refund the stake to the balance that actually paid it
  #
  # db/20-post/011 recorded this as a known quirk and deliberately did not fix
  # it, on the grounds that it needed evidence rather than a guess. Here is the
  # evidence, and it says the quirk is reachable.
  #
  # THE PAIR THAT DISAGREES.
  #
  # deduct_stake_from_balance() (20260725000000, BEFORE INSERT ON players) SPLITS
  # the stake across both balances:
  #
  #     IF user_deposited >= stake_amount_val THEN
  #       deduct_from_deposited := stake_amount_val;
  #       deduct_from_won       := 0;
  #     ELSE
  #       deduct_from_deposited := user_deposited;
  #       deduct_from_won       := stake_amount_val - user_deposited;
  #     END IF;
  #
  # refund_player_stake() (20251225111615, BEFORE DELETE ON players) does not:
  #
  #     UPDATE telegram_users
  #        SET deposited_balance = deposited_balance + game_stake_amount
  #
  # -- everything, unconditionally, to deposited_balance.
  #
  # So a player whose deposits do not cover the stake pays partly from
  # won_balance and is refunded entirely into deposited_balance. The totals
  # reconcile; the SPLIT does not.
  #
  # WHY THAT COSTS THE PLAYER REAL MONEY. db/20-post/007 pays out won_balance
  # only -- deposits are not withdrawable (20251217172433), because paying them
  # out would make this a way to move money in and straight back out. So every
  # release converts withdrawable money into non-withdrawable money, silently.
  # Nobody is credited twice and the house does not gain; the player simply
  # loses the ability to cash out an amount they had already won.
  #
  # WHY IT MATTERS NOW rather than whenever. Until db/20-post/011 there was no
  # way to delete a players row at all -- /deselect-card answered 404 and 008
  # revoked the table privilege -- so this trigger fired only on an operator's
  # manual delete. 011 gave every player a button that reaches it.
  #
  # ---------------------------------------------------------------------------
  # THE FIX: record the split, then honour it
  # ---------------------------------------------------------------------------
  #
  # refund_player_stake() cannot infer the split -- by the time it runs, the
  # balances have already moved and the original proportions are unrecoverable.
  # So the deducting trigger writes them onto the row it is already inserting,
  # and the refunding trigger reads them back off the row it is already deleting.
  # No extra query, no new lock, nothing to keep in sync.
  #
  # NULL means "recorded before this migration". Those rows fall back to the old
  # all-to-deposited behaviour, which is what actually happened to them --
  # inventing a split for a historical row would be worse than preserving an
  # imperfect one, because it would move money based on a guess.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

ALTER TABLE players
  ADD COLUMN IF NOT EXISTS stake_from_deposited integer,
  ADD COLUMN IF NOT EXISTS stake_from_won integer;

COMMENT ON COLUMN players.stake_from_deposited IS
  'How much of this player''s stake came from deposited_balance. NULL for rows created before db/20-post/014; those refund entirely to deposited_balance, which is what happened to them.';
COMMENT ON COLUMN players.stake_from_won IS
  'How much of this player''s stake came from won_balance. Read by refund_player_stake() so a release returns money to the balance that paid it -- only won_balance is withdrawable.';

-- ---------------------------------------------------------------------------
-- 1. Record the split at deduction time
--
-- The body is 20260725000000's, unchanged except for the two assignments to
-- NEW. Restated in full rather than patched, because it is a BEFORE INSERT
-- trigger on the money path and a reader should be able to see the whole thing
-- in one place -- the same reason 007 restates rather than composes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION deduct_stake_from_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  stake_amount_val integer;
  user_deposited integer;
  user_won integer;
  total_available integer;
  deduct_from_deposited integer;
  deduct_from_won integer;
BEGIN
  SELECT stake_amount INTO stake_amount_val
  FROM games
  WHERE id = NEW.game_id;

  IF stake_amount_val IS NULL THEN
    RAISE EXCEPTION 'Game not found';
  END IF;

  -- FOR UPDATE: without this, two concurrent joins by the same user both read
  -- the pre-deduction balance and both pass the affordability check below.
  SELECT COALESCE(deposited_balance, 0), COALESCE(won_balance, 0)
  INTO user_deposited, user_won
  FROM telegram_users
  WHERE telegram_user_id = NEW.telegram_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User % not found', NEW.telegram_user_id;
  END IF;

  total_available := user_deposited + user_won;

  IF total_available < stake_amount_val THEN
    RAISE EXCEPTION 'INSUFFICIENT_BALANCE: stake % exceeds available balance %',
      stake_amount_val, total_available
      USING ERRCODE = 'check_violation';
  END IF;

  IF user_deposited >= stake_amount_val THEN
    deduct_from_deposited := stake_amount_val;
    deduct_from_won := 0;
  ELSE
    deduct_from_deposited := user_deposited;
    deduct_from_won := stake_amount_val - user_deposited;
  END IF;

  -- Names this movement in the balance ledger (db/20-post/019).
  PERFORM set_config('app.ledger_reason', 'stake', true);

  UPDATE telegram_users
  SET
    deposited_balance = deposited_balance - deduct_from_deposited,
    won_balance = won_balance - deduct_from_won,
    balance = balance - stake_amount_val,
    total_spent = total_spent + stake_amount_val
  WHERE telegram_user_id = NEW.telegram_user_id;

  -- THE ADDITION. Written to NEW rather than to a second UPDATE, because this
  -- is a BEFORE trigger and the row has not been stored yet -- so it costs
  -- nothing and cannot drift from the deduction it describes.
  NEW.stake_from_deposited := deduct_from_deposited;
  NEW.stake_from_won := deduct_from_won;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Honour the split at refund time
--
-- Body from 20251225111615, with the single UPDATE to telegram_users replaced.
-- The pot and commission handling is unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refund_player_stake()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  game_stake_amount integer;
  new_total_pot integer;
  commission_rate_val integer;
  refund_deposited integer;
  refund_won integer;
BEGIN
  IF OLD.telegram_user_id IS NULL THEN
    RETURN OLD;
  END IF;

  SELECT stake_amount INTO game_stake_amount
  FROM games
  WHERE id = OLD.game_id;

  IF game_stake_amount IS NULL THEN
    RETURN OLD;
  END IF;

  -- NULL means the row predates db/20-post/014, so the split was never
  -- recorded. Fall back to all-to-deposited: that is what actually happened to
  -- those rows, and inventing a split for them would move money on a guess.
  IF OLD.stake_from_deposited IS NULL AND OLD.stake_from_won IS NULL THEN
    refund_deposited := game_stake_amount;
    refund_won := 0;
  ELSE
    -- The RECORDED amounts, deliberately -- not the game's current
    -- stake_amount. If an operator changes the stake after a player has joined,
    -- these still say what was actually taken from them. Refunding the current
    -- stake instead would hand the player the difference, which is a balance
    -- inflated by an admin edit.
    refund_deposited := COALESCE(OLD.stake_from_deposited, 0);
    refund_won := COALESCE(OLD.stake_from_won, 0);
  END IF;

  -- Names this movement in the balance ledger (db/20-post/019).
  PERFORM set_config('app.ledger_reason', 'stake_refund', true);

  UPDATE telegram_users
  SET
    deposited_balance = deposited_balance + refund_deposited,
    won_balance       = won_balance + refund_won,
    total_spent       = GREATEST(0, total_spent - (refund_deposited + refund_won))
  WHERE telegram_user_id = OLD.telegram_user_id;

  -- ONE reader, shared with update_game_pot(). This used to be an inline read
  -- with a fallback of 25 while update_game_pot() fell back to 20, so releasing
  -- a card rebuilt the pot at a different house cut than joining had built it
  -- with. See db/20-post/013 for that, and for the worse half: with the setting
  -- row absent, neither fallback fired at all.
  commission_rate_val := commission_rate();

  SELECT GREATEST(0, total_pot - game_stake_amount) INTO new_total_pot
  FROM games
  WHERE id = OLD.game_id;

  UPDATE games
  SET
    total_pot = new_total_pot,
    winner_prize = FLOOR(new_total_pot * (100 - commission_rate_val) / 100)
  WHERE id = OLD.game_id;

  RETURN OLD;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Assert the two agree, BY RUNNING THEM
--
-- Not by comparing the two function bodies, which would prove only that I wrote
-- the same arithmetic twice. A player is given a balance that forces a split,
-- joined, and released; the assertion is that they end up where they started.
--
-- This is the shape 003 settled on -- "a static assertion about a security
-- control is not a test of that control" -- and the shape 012's probe needed
-- after it was found passing vacuously.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tg     bigint := -999000001;   -- negative, so it cannot collide with a real id
  v_game   uuid;
  v_stake  integer;
  v_player uuid;
  v_dep    integer;
  v_won    integer;
BEGIN
  SELECT id, stake_amount INTO v_game, v_stake
    FROM games WHERE status = 'waiting' LIMIT 1;

  -- No waiting game: try to make one the way the system does, rather than
  -- writing an INSERT here. game_tick()'s own comment explains why hand-rolling
  -- one is a trap -- `code` was in the original CREATE TABLE and dropped by the
  -- next migration, so reading the initial schema gets you a column that has not
  -- existed for months. ensure_waiting_game_exists() is the reliable reference.
  IF v_game IS NULL AND EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'ensure_waiting_game_exists'
  ) THEN
    PERFORM ensure_waiting_game_exists();
    SELECT id, stake_amount INTO v_game, v_stake
      FROM games WHERE status = 'waiting' LIMIT 1;
  END IF;

  -- RAISE, DO NOT SKIP.
  --
  -- The first version of this block returned quietly when it could not build the
  -- case, and it did so twice over: the fixture stake was 10 where the probe
  -- wanted >30, and the fixture installed neither trigger, so a green run proved
  -- that inserting and deleting a row changed nothing. That is the same vacuity
  -- 003 and 004 both document, and 012's probe had it too. A check that cannot
  -- run must say so as a failure, not as a NOTICE nobody reads.
  IF v_game IS NULL THEN
    RAISE EXCEPTION
      'cannot verify the refund split: no waiting game exists and ensure_waiting_game_exists() is unavailable. Run SELECT game_tick(); and re-apply.';
  END IF;

  IF coalesce(v_stake, 0) < 2 THEN
    RAISE EXCEPTION
      'cannot verify the refund split: stake_amount is %, so no split is possible. A stake below 2 is not a real configuration.',
      v_stake;
  END IF;

  -- One unit short of the stake, so the deduction MUST take the remainder from
  -- won_balance. Derived from the stake rather than hardcoded, which is what
  -- made the first version skip on a stake of 10.
  INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
  VALUES (v_tg, '_split_probe', v_stake - 1, 100)
  ON CONFLICT (telegram_user_id) DO UPDATE
    SET deposited_balance = v_stake - 1, won_balance = 100;

  -- name and card are NOT NULL on the real table (20251109203131) and were
  -- nullable in db/test/fixture.sql, so the first version of this probe passed
  -- the harness and failed the first real apply with
  --
  --   ERROR: null value in column "name" of relation "players"
  --
  -- The fixture is now strict about both, so the harness catches this class of
  -- thing rather than the dev database doing it. The exception handler below
  -- turns a future addition into a message that says what to do about it,
  -- instead of a constraint name.
  BEGIN
    INSERT INTO players (game_id, telegram_user_id, selected_number, name, card)
    VALUES (v_game, v_tg, 9999, '_split_probe', '[]'::jsonb)
    RETURNING id INTO v_player;
  EXCEPTION WHEN not_null_violation THEN
    DELETE FROM telegram_users WHERE telegram_user_id = v_tg;
    RAISE EXCEPTION
      'the refund-split probe cannot insert a players row: %. A NOT NULL column has been added since this file was written -- supply it in the INSERT above, and add it to db/test/fixture.sql so the harness catches the next one.',
      SQLERRM;
  END;

  -- Prove the deduction actually split, before trusting what the refund does
  -- with it. Without this the next assertion passes on a database where the
  -- deduct trigger is absent -- balances never move, so they trivially match.
  SELECT deposited_balance, won_balance INTO v_dep, v_won
    FROM telegram_users WHERE telegram_user_id = v_tg;

  IF v_dep <> 0 OR v_won <> 99 THEN
    DELETE FROM players WHERE id = v_player;
    DELETE FROM telegram_users WHERE telegram_user_id = v_tg;
    RAISE EXCEPTION
      'the stake deduction did not split as expected: deposited %/0, won %/99 for a stake of %. Either deduct_stake_from_balance is not installed, or it no longer splits -- and this file rewrote it, so that is worth knowing.',
      v_dep, v_won, v_stake;
  END IF;

  DELETE FROM players WHERE id = v_player;

  SELECT deposited_balance, won_balance INTO v_dep, v_won
    FROM telegram_users WHERE telegram_user_id = v_tg;

  DELETE FROM telegram_users WHERE telegram_user_id = v_tg;

  IF v_dep <> v_stake - 1 OR v_won <> 100 THEN
    RAISE EXCEPTION
      'join-then-release did not restore the split: deposited %/%, won %/100. Withdrawable money is being converted to non-withdrawable, because db/20-post/007 pays out won_balance only.',
      v_dep, v_stake - 1, v_won;
  END IF;

  RAISE NOTICE 'refund split: a stake paid from both balances is returned to both';
END $$;
