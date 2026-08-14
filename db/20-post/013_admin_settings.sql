/*
  # Writing a setting, as an operator, without re-opening what 003 closed
  #
  # src/components/Admin.tsx has a settings form that POSTs
  # /functions/v1/update-settings -- an inherited Deno name that 404s, so the
  # form has never saved anything. db/20-post/012 also revoked UPDATE on every
  # table from clients, so it could not be fixed by pointing it at PostgREST.
  #
  # ---------------------------------------------------------------------------
  # THE TRAP, and it is the reason this is an allowlist rather than a passthrough
  # ---------------------------------------------------------------------------
  #
  # That form saves SIX keys, and the first of them is telegram_bot_token.
  #
  # db/20-post/003 exists because `curl /rest/v1/settings` returned a LIVE bot
  # token to an anonymous caller. It excluded that key from the read allowlist
  # and then actively redacted the stored value to '', with this reasoning:
  #
  #   "it is not merely 'send messages as the bot'. It is the HMAC key Telegram
  #    Mini Apps use to sign initData. Anyone holding it can forge a valid
  #    initData payload for ANY telegram user id -- i.e. authenticate as any
  #    player and act on their balance through the application's own logic."
  #
  # and, on where it belongs:
  #
  #   "On AWS these values come from SSM Parameter Store, injected as environment
  #    variables at container start; the database is the wrong place for them
  #    entirely."
  #
  # So a faithful port of update-settings would write a live bot token straight
  # back into the table 003 cleared, and the next policy mistake re-exposes it.
  # Porting the route as-is would have undone the fix while looking like
  # restoring a feature.
  #
  # The token is therefore NOT WRITABLE HERE. It lives at
  # /<prefix>/telegram/bot_token in SSM, Terraform declares it, the ECS agent
  # injects it, and rotating it is `aws ssm put-parameter` plus a redeploy. The
  # admin form drops the field.
  #
  # ---------------------------------------------------------------------------
  # WHAT IS WRITABLE, and why each one
  # ---------------------------------------------------------------------------
  #
  # Five keys, all presentation or business configuration, all already in 003's
  # READ allowlist -- which is the invariant asserted at the bottom: an operator
  # should never be able to write a value they cannot then see, because the
  # symptom is a form that silently reverts.
  #
  #   telegram_bot_username   shown to players; not a credential
  #   support_contact         shown to players
  #   user_instructions       shown to players
  #   game_url                shown to players
  #   commission_rate         business config, and the one that touches money --
  #                           it sets the prize/fee split, so it is range-checked
  #                           and its changes are logged by the route
  #
  # Anything not named below is unwritable, and adding to the list is a
  # deliberate, reviewable line. Same shape as the EXECUTE allowlist in 004 and
  # the read allowlist in 003, for the same reason: a key added to this table in
  # future is not writable because nobody thought about it.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

CREATE OR REPLACE FUNCTION admin_update_setting(
  p_key text,
  p_value text,
  p_admin_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Kept in SQL rather than only in the route, so the allowlist is one thing
  -- the migration harness can assert against 003's read allowlist. A guard that
  -- lives only in application code is a guard the next route forgets.
  v_writable text[] := ARRAY[
    'telegram_bot_username',
    'support_contact',
    'user_instructions',
    'game_url',
    'commission_rate'
  ];
  v_rate integer;
BEGIN
  IF p_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'NO_ADMIN');
  END IF;

  IF p_key IS NULL OR NOT (p_key = ANY(v_writable)) THEN
    -- Names the key back deliberately: an operator mistyping one should be told
    -- which, and the list is not a secret -- it is in this file and in 003.
    RETURN jsonb_build_object(
      'success', false, 'error_code', 'NOT_WRITABLE', 'key', p_key,
      'writable', to_jsonb(v_writable));
  END IF;

  -- commission_rate is the one that decides money. It is read as
  -- `value::integer` by refund_player_stake() and by the pot calculations, so a
  -- non-numeric value does not fail validation somewhere visible -- it raises
  -- inside a trigger during a refund, which is the worst possible moment.
  IF p_key = 'commission_rate' THEN
    BEGIN
      v_rate := p_value::integer;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('success', false, 'error_code', 'NOT_AN_INTEGER');
    END;

    -- 0 is legitimate (a promotion). The ceiling is a sanity bound, not a
    -- policy: a house edge above half is a mistyped number, not a decision.
    IF v_rate < 0 OR v_rate > 50 THEN
      RETURN jsonb_build_object(
        'success', false, 'error_code', 'OUT_OF_RANGE', 'min', 0, 'max', 50);
    END IF;
  END IF;

  -- Upsert: a key that has never been set should be settable, and the table has
  -- no row for several of these on a fresh database.
  INSERT INTO settings (id, value, updated_at)
  VALUES (p_key, p_value, now())
  ON CONFLICT (id) DO UPDATE
    SET value = EXCLUDED.value,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'key', p_key);
END;
$$;

-- ---------------------------------------------------------------------------
-- service_role only, for the reason db/20-post/004 established
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION admin_update_setting(text, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_update_setting(text, text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- commission_rate(): ONE reader, because there were two and they disagreed
--
-- THE BUG THIS CLOSES IS NOT THE DISAGREEMENT. IT IS WHAT BOTH DO WHEN THE ROW
-- IS ABSENT.
--
-- Two functions computed winner_prize from this setting, each with its own
-- fallback:
--
--   update_game_pot()      (AFTER INSERT ON players)   COALESCE(..., 20)
--   refund_player_stake()  (BEFORE DELETE ON players)  COALESCE(..., 25)
--
-- So the pot's payout ratio depended on whether the last thing that happened
-- was a join or a release. That alone is a bug: 10 ETB pays 8 after a join and
-- 7.50 after somebody leaves.
--
-- The worse half is that NEITHER fallback fires when the row is MISSING.
-- `SELECT COALESCE(value::integer, 20) INTO v FROM settings WHERE id = ...`
-- puts the COALESCE inside the query, so with no matching row the query returns
-- NO ROWS, PL/pgSQL assigns NULL to the target, and the COALESCE never runs.
-- Measured on postgres:16 rather than reasoned about:
--
--   settings row absent -> commission_rate_val = NULL
--                       -> FLOOR(pot * (100 - NULL) / 100) = NULL
--
-- refund_player_stake() catches that with a following IF; update_game_pot() has
-- no such guard, so winner_prize is set to NULL. atomic_claim_bingo then pays
-- FLOOR(COALESCE(winner_prize, 0) / n_winners) -- and EVERY WINNER IS PAID ZERO,
-- silently, with the game recorded as finished and winners_paid set.
--
-- WHY THIS RAISES INSTEAD OF DEFAULTING.
--
-- A default would keep the game running on a house cut nobody chose, which is
-- the "reports success and does the wrong thing" shape this repository keeps
-- finding. The row is not an optional convenience: it is an invariant the
-- migration below establishes and asserts, so its absence means a broken
-- database, not a routine state. Refusing turns that into a failed join
-- somebody investigates, instead of a payout that quietly rounds to nothing.
--
-- The bounds match admin_update_setting's, restated here because this is the
-- reader: a value that got in by some other route than that function -- psql,
-- a restore from an older dump -- must not be trusted just because it is stored.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION commission_rate()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_raw  text;
  v_rate integer;
BEGIN
  -- Two statements, not one, so "no row" and "row holding rubbish" are
  -- distinguishable in the error. They need different fixes.
  SELECT value INTO v_raw FROM settings WHERE id = 'commission_rate';

  IF v_raw IS NULL THEN
    RAISE EXCEPTION
      'settings.commission_rate is missing. Pot arithmetic will not proceed on an assumed house cut -- every winner would be paid zero. Restore it with: SELECT admin_update_setting(''commission_rate'', ''20'', <admin_uuid>);'
      USING ERRCODE = 'no_data_found';
  END IF;

  BEGIN
    v_rate := btrim(v_raw)::integer;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION
      'settings.commission_rate is %, which is not an integer.', quote_literal(v_raw)
      USING ERRCODE = 'invalid_parameter_value';
  END;

  IF v_rate < 0 OR v_rate > 50 THEN
    RAISE EXCEPTION
      'settings.commission_rate is %, outside the 0-50 range admin_update_setting enforces.', v_rate
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  RETURN v_rate;
END;
$$;

COMMENT ON FUNCTION commission_rate() IS
  'The house cut, as a percentage. The single reader of settings.commission_rate: update_game_pot() and refund_player_stake() both call this so a pot cannot be built at one rate and rebuilt at another. Raises rather than defaulting -- see db/20-post/013.';

-- A new function is EXECUTE-able by PUBLIC by default, and db/20-post/004 ran
-- long before this file. So the revoke is explicit, exactly as 015 and 016 do.
-- Nothing client-side needs this: the SPA is shown winner_prize, not the rate
-- that produced it.
REVOKE EXECUTE ON FUNCTION commission_rate() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION commission_rate() TO service_role;

DO $$
DECLARE
  v_writable text[] := ARRAY[
    'telegram_bot_username', 'support_contact', 'user_instructions',
    'game_url', 'commission_rate'
  ];
  v_key text;
  v_unreadable text;
BEGIN
  IF has_function_privilege('authenticated', 'admin_update_setting(text,text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'admin_update_setting is callable by authenticated; any player could rewrite the commission rate.';
  END IF;

  -- THE INVARIANT: nothing writable may be a secret.
  --
  -- Checked by EXECUTION rather than by comparing two lists I wrote, which is
  -- the mistake 003 documents in the assertion it replaced -- "it verified that
  -- a string I wrote was absent from another string I wrote". Every writable key
  -- is written, then read back AS anon. If a key is writable and invisible to
  -- anon it is not presentation config, and if it is writable and IS a secret
  -- then anon can now see a secret. Either way this fails.
  FOREACH v_key IN ARRAY v_writable
  LOOP
    INSERT INTO settings (id, value, updated_at)
    VALUES (v_key, coalesce((SELECT value FROM settings WHERE id = v_key), ''), now())
    ON CONFLICT (id) DO NOTHING;
  END LOOP;

  SET LOCAL ROLE anon;
  SELECT string_agg(k, ', ') INTO v_unreadable
    FROM unnest(v_writable) k
   WHERE NOT EXISTS (SELECT 1 FROM settings s WHERE s.id = k);
  RESET ROLE;

  IF v_unreadable IS NOT NULL THEN
    RAISE EXCEPTION
      'admin_update_setting can write keys anon cannot read: %. An operator writing a value they cannot see is a form that silently reverts -- and a key outside 003''s read allowlist is one 003 considered a secret.',
      v_unreadable;
  END IF;

  -- Stated positively as well, because this is the whole point of the file.
  IF 'telegram_bot_token' = ANY(v_writable) THEN
    RAISE EXCEPTION
      'telegram_bot_token is writable. It is the HMAC key for Mini App initData; db/20-post/003 redacted it from this table and it belongs in SSM.';
  END IF;

  RAISE NOTICE 'admin settings: five presentation keys, no secrets, service_role only';
END $$;
