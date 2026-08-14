/*
  # Bank withdrawals: the mirror of the deposit queue
  #
  # The player asks to be paid out to THEIR OWN TeleBirr or bank account, the
  # operator sends the money by hand, and marks it done. Symmetric with
  # db/20-post/006 and, like it, deliberately manual -- the operator moving money
  # from their own account is the step that cannot be automated here.
  #
  # THE RISK IS THE MIRROR IMAGE, AND WORSE. A deposit credited twice costs the
  # house what the player did not send. A withdrawal PAID twice costs the house
  # real money out of a real bank account, and there is no reversing a TeleBirr
  # transfer. So the same guarantees, applied harder:
  #
  #   one payout per request      UPDATE ... WHERE status = 'pending' is the lock
  #   decided rows are frozen     a trigger, so a paid request cannot be reopened
  #   no overdraft                and this is the part with no equivalent in 006
  #
  # WHY OVERDRAFT IS THE HARD ONE.
  #
  # A player with 100 winnings can file ten requests for 100 each before the
  # operator looks at any of them. Nothing in the request itself is wrong; the
  # tenth is only invalid because of the nine before it. Checking the balance at
  # PAYOUT time is too late -- by then the operator has already sent nine
  # transfers.
  #
  # get_available_balance() already exists for exactly this and returns
  # won_balance minus everything currently pending. It is the right calculation.
  # What it cannot do on its own is stop two requests racing between the check
  # and the insert, so request_bank_withdrawal() locks the player's row FOR
  # UPDATE first, which serialises every request for one player.
  #
  # WON_BALANCE ONLY, never deposited_balance. Deposits are not withdrawable in
  # this system (20251217172433). Paying them out would make this a way to move
  # money in and straight back out, which is the shape of every laundering
  # complaint a payment provider will ever make about a game.
  #
  # NOTHING IS DEDUCTED AT REQUEST TIME. The balance moves when the operator
  # confirms they sent the money, and until then the request simply reduces what
  # get_available_balance() reports. A rejected request therefore needs no refund
  # -- there is nothing to give back, which removes a whole class of
  # refund-went-wrong bugs.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- The inherited table is keyed on telegram_user_id (bigint), where
-- deposit_requests uses the uuid. Inconsistent, and left alone deliberately: it
-- already carries data shape, RLS and a foreign key, and rekeying a money table
-- to tidy a naming difference is not worth the risk. The routes derive the
-- bigint from the verified token, exactly as select-card does.
ALTER TABLE withdrawal_requests
  ADD COLUMN IF NOT EXISTS payout_reference text;

COMMENT ON COLUMN withdrawal_requests.payout_reference IS
  'The transaction reference from the operator''s OWN transfer when paying out. The receipt, not the request.';

-- Stops a second payout being recorded against a request already paid, at the
-- database rather than only in the function. Partial, so rejected and pending
-- rows are unaffected.
CREATE UNIQUE INDEX IF NOT EXISTS withdrawal_requests_payout_reference_unique
  ON withdrawal_requests (lower(payout_reference))
  WHERE payout_reference IS NOT NULL;

CREATE INDEX IF NOT EXISTS withdrawal_requests_pending
  ON withdrawal_requests (requested_at) WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- Say what the read policy means, instead of being right by accident
--
-- The inherited policy is:
--
--   USING (telegram_user_id = (SELECT telegram_user_id FROM telegram_users
--                              WHERE telegram_user_id = withdrawal_requests.telegram_user_id))
--
-- which compares a value to itself. As written it is a tautology, granted TO
-- public, over a table holding amounts, bank names, account numbers and account
-- holder names.
--
-- It does not currently leak, and the reason is worth knowing because it is not
-- this policy. The subquery reads telegram_users, and db/20-post/004 scoped that
-- to `id = auth.uid()` -- so for a row belonging to someone else the subquery
-- finds nothing, returns NULL, the comparison is NULL, and the row is filtered.
-- Verified: an anonymous request returns content-range */0 against a table with
-- rows in it.
--
-- So the protection comes from a DIFFERENT table's policy. Loosen 004 and this
-- silently becomes a public list of every player's bank account. Replaced with
-- the condition it was always meant to express.
DROP POLICY IF EXISTS "Users can read own withdrawal requests" ON withdrawal_requests;
DROP POLICY IF EXISTS "Users can view own withdrawal requests" ON withdrawal_requests;
-- And this file's own policy, so a second run replaces it rather than failing on
-- "already exists". These files are repeatable; the migration test applies them
-- twice for exactly this reason, and caught this omission.
DROP POLICY IF EXISTS "Players read their own withdrawal requests" ON withdrawal_requests;

CREATE POLICY "Players read their own withdrawal requests"
  ON withdrawal_requests FOR SELECT TO authenticated
  USING (telegram_user_id = (SELECT telegram_user_id FROM telegram_users WHERE id = auth.uid()));

-- No INSERT policy, deliberately. src/components/BankWithdrawalModal.tsx inserts
-- into this table directly from the browser, which fails on RLS today and should
-- keep failing: a client-side insert would set telegram_user_id and amount with
-- no balance check and no serialisation, so a player could file withdrawals
-- against someone else, or ten against their own balance at once. Requests go
-- through request_bank_withdrawal(), below.

DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(policyname, '; ') INTO v_bad
  FROM pg_policies
  WHERE tablename = 'withdrawal_requests'
    AND cmd IN ('INSERT', 'UPDATE', 'ALL')
    AND NOT ('service_role' = ANY(roles));

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'withdrawal_requests has a non-service_role write policy: %. A player could file or alter a payout directly.',
      v_bad;
  END IF;
  RAISE NOTICE 'withdrawal_requests: reads are owner-scoped, writes are service_role only';
END $$;

-- ---------------------------------------------------------------------------
-- A decided request is immutable, exactly as in 006
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION withdrawal_requests_freeze_decided()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IN ('completed', 'rejected') THEN
    RAISE EXCEPTION
      'withdrawal request % is already %; a decided request cannot be changed',
      OLD.id, OLD.status
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS withdrawal_requests_no_redecide ON withdrawal_requests;
CREATE TRIGGER withdrawal_requests_no_redecide
  BEFORE UPDATE ON withdrawal_requests
  FOR EACH ROW EXECUTE FUNCTION withdrawal_requests_freeze_decided();

-- ---------------------------------------------------------------------------
-- Requesting
--
-- FOR UPDATE on the player's row is what makes the balance check mean anything.
-- Without it, two requests submitted together both read the same available
-- balance, both pass, and the player has requested twice what they have.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION request_bank_withdrawal(
  p_telegram_user_id bigint,
  p_amount numeric,
  p_bank_name text,
  p_account_number text,
  p_account_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_won numeric;
  v_pending numeric;
  v_available numeric;
  v_id uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'INVALID_AMOUNT');
  END IF;

  IF coalesce(trim(p_account_number), '') = '' OR coalesce(trim(p_account_name), '') = '' THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'MISSING_DESTINATION');
  END IF;

  -- Serialises every request for this player. Concurrent callers queue here.
  SELECT won_balance INTO v_won
    FROM telegram_users
   WHERE telegram_user_id = p_telegram_user_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'USER_NOT_FOUND');
  END IF;

  SELECT coalesce(sum(amount), 0) INTO v_pending
    FROM withdrawal_requests
   WHERE telegram_user_id = p_telegram_user_id
     AND status IN ('pending', 'processing');

  v_available := coalesce(v_won, 0) - v_pending;

  IF v_available < p_amount THEN
    RETURN jsonb_build_object(
      'success', false, 'error_code', 'INSUFFICIENT_BALANCE',
      'available', v_available, 'requested', p_amount,
      'won_balance', coalesce(v_won, 0), 'already_pending', v_pending
    );
  END IF;

  INSERT INTO withdrawal_requests
    (telegram_user_id, amount, bank_name, account_number, account_name)
  VALUES
    (p_telegram_user_id, p_amount, p_bank_name, trim(p_account_number), trim(p_account_name))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'request_id', v_id, 'available_after', v_available - p_amount);
END;
$$;

-- ---------------------------------------------------------------------------
-- Paying out
--
-- Called AFTER the operator has actually sent the money. The reference is their
-- own transfer's receipt, which is what makes "did we pay this" answerable
-- later without trusting memory.
--
-- The balance moves HERE, not at request time, so a request that is never
-- processed leaves the player's balance untouched.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION complete_bank_withdrawal(
  p_request_id uuid,
  p_admin_id uuid,
  p_payout_reference text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row withdrawal_requests%ROWTYPE;
  v_won numeric;
BEGIN
  IF p_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'NO_ADMIN');
  END IF;

  UPDATE withdrawal_requests
     SET status            = 'completed',
         processed_at      = now(),
         processed_by_admin = p_admin_id::text,
         payout_reference  = nullif(trim(p_payout_reference), ''),
         admin_notes       = p_note
   WHERE id = p_request_id
     AND status IN ('pending', 'processing')
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'NOT_PENDING');
  END IF;

  -- Deduct now. The row is locked by the UPDATE above for the rest of this
  -- transaction, so nothing else can pay the same request.
  SELECT won_balance INTO v_won
    FROM telegram_users WHERE telegram_user_id = v_row.telegram_user_id FOR UPDATE;

  IF coalesce(v_won, 0) < v_row.amount THEN
    -- Should be unreachable: the request could not have been created without the
    -- balance, and winnings only decrease through this path. Raising rather than
    -- returning, because a silent negative balance is worse than a failed payout
    -- the operator has to look at.
    RAISE EXCEPTION
      'withdrawal % would overdraw: won_balance % is below amount %',
      v_row.id, coalesce(v_won, 0), v_row.amount
      USING ERRCODE = 'check_violation';
  END IF;

  -- Names this movement in the balance ledger (db/20-post/019). This is the
    -- entry that matters most: money has already left a real bank account.
  PERFORM set_config('app.ledger_reason', 'withdrawal_payout', true);

  UPDATE telegram_users
     SET won_balance     = won_balance - v_row.amount,
         total_withdrawn = coalesce(total_withdrawn, 0) + v_row.amount
   WHERE telegram_user_id = v_row.telegram_user_id;

  RETURN jsonb_build_object(
    'success', true, 'request_id', v_row.id,
    'paid', v_row.amount, 'telegram_user_id', v_row.telegram_user_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION reject_bank_withdrawal(
  p_request_id uuid,
  p_admin_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'NO_ADMIN');
  END IF;

  -- No balance change: nothing was deducted at request time, so there is nothing
  -- to refund. The request simply stops counting against available balance.
  UPDATE withdrawal_requests
     SET status             = 'rejected',
         processed_at       = now(),
         processed_by_admin = p_admin_id::text,
         rejection_reason   = p_reason
   WHERE id = p_request_id
     AND status IN ('pending', 'processing')
  RETURNING id INTO v_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'NOT_PENDING');
  END IF;

  RETURN jsonb_build_object('success', true, 'request_id', v_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- service_role only, for the reason db/20-post/004 established
--
-- All three take an identity as a parameter and do not verify it. Exposed to
-- `authenticated`, request_bank_withdrawal would let a player file against
-- somebody else's balance and complete_bank_withdrawal would let them mark their
-- own payout done.
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION request_bank_withdrawal(bigint, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION complete_bank_withdrawal(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION reject_bank_withdrawal(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION request_bank_withdrawal(bigint, numeric, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION complete_bank_withdrawal(uuid, uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION reject_bank_withdrawal(uuid, uuid, text) TO service_role;

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'complete_bank_withdrawal(uuid,uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'complete_bank_withdrawal is callable by authenticated; a player could mark their own payout done.';
  END IF;
  RAISE NOTICE 'bank withdrawals: service_role only';
END $$;
