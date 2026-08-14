/*
  # Manual deposit review: a queue, a state machine, and one place that credits
  #
  # THE WORKFLOW THIS IMPLEMENTS, which is the operator's, not an automated one:
  #
  #   1. the player transfers to the house TeleBirr / CBE account themselves
  #   2. the bank notifies the OPERATOR on their own phone -- outside this system
  #   3. the player submits a claim here: bank, reference number, amount
  #   4. the operator reads their real bank statement and approves or rejects
  #
  # Step 4 is a human reading a bank account. That is the trust anchor, and it is
  # why the inherited SMS-matching pipeline (bank_sms_messages, match_user_sms,
  # extract_amount_from_sms, the phone forwarder) is deliberately NOT used here:
  # it automates a decision a person is going to make by hand anyway, and it
  # brings a parsing surface and a phone dependency with it. The tables remain;
  # nothing in this path touches them.
  #
  # THE RISK IS NOT FORGERY, IT IS DOUBLE CREDITING.
  #
  # A player cannot invent money -- the operator is looking at the real statement.
  # What can go wrong is the same real transfer being credited twice: two claims
  # for one bank reference, a double-clicked approve button, two operators working
  # the queue at once, or a retried request. Every constraint below exists for
  # that, not for fraud.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

CREATE TABLE IF NOT EXISTS deposit_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- The claimant, by the uuid the JWT proves. Never a telegram id from a body.
  player_id uuid NOT NULL REFERENCES telegram_users(id) ON DELETE CASCADE,

  -- Which house account they say they paid into. The NAME is denormalised
  -- alongside the id on purpose: bank_options rows get edited and deactivated,
  -- and a decision made months ago must still say which account it was about.
  bank_option_id uuid REFERENCES bank_options(id) ON DELETE SET NULL,
  bank_name text NOT NULL,

  -- The bank's own transaction reference. This is the anti-double-credit key.
  reference_number text NOT NULL,

  -- What the PLAYER says they sent. A hint for the operator, never the credit.
  claimed_amount integer NOT NULL CHECK (claimed_amount > 0),

  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected')),

  -- What the operator ACTUALLY saw in the statement, and therefore credited.
  -- Separate from claimed_amount so a mismatch is recorded rather than silently
  -- resolved in either direction.
  credited_amount integer CHECK (credited_amount IS NULL OR credited_amount > 0),

  admin_note text,
  decided_by uuid REFERENCES telegram_users(id) ON DELETE SET NULL,
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),

  -- A decided row must say who decided it and when; an approved row must say how
  -- much was credited. Enforced here so no code path can leave a half-decision.
  CONSTRAINT deposit_requests_decision_complete CHECK (
    (status = 'pending'  AND decided_by IS NULL AND decided_at IS NULL AND credited_amount IS NULL)
    OR (status = 'rejected' AND decided_at IS NOT NULL)
    OR (status = 'approved' AND decided_at IS NOT NULL AND credited_amount IS NOT NULL)
  )
);

-- THE CONSTRAINT THAT MATTERS MOST.
--
-- One bank transaction can be claimed once, by anybody. Without this, the same
-- reference submitted twice -- by the same player retrying, or by two players --
-- becomes two approvable rows and the operator has no way to notice at approval
-- time, because each looks legitimate in isolation.
--
-- Case-insensitive, because bank references arrive transcribed by hand and
-- "FT25ABC" and "ft25abc" are the same transaction.
CREATE UNIQUE INDEX IF NOT EXISTS deposit_requests_reference_unique
  ON deposit_requests (bank_name, lower(reference_number));

CREATE INDEX IF NOT EXISTS deposit_requests_pending
  ON deposit_requests (created_at) WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS deposit_requests_by_player
  ON deposit_requests (player_id, created_at DESC);

ALTER TABLE deposit_requests ENABLE ROW LEVEL SECURITY;

-- A player sees their own claims and nothing else. The operator's queue is read
-- through the admin API, which connects as app_service.
--
-- app_service bypasses RLS because db/00-bootstrap/001 sets BYPASSRLS on the role
-- ITSELF. Membership of service_role is not enough and never was: BYPASSRLS is an
-- attribute, not a privilege, so it does not travel through GRANT. See that file
-- -- the distinction cost a working deposit route reading an empty bank_options.
DROP POLICY IF EXISTS "Players read their own deposit requests" ON deposit_requests;
CREATE POLICY "Players read their own deposit requests"
  ON deposit_requests FOR SELECT TO authenticated
  USING (player_id = auth.uid());

DROP POLICY IF EXISTS "Service role manages deposit requests" ON deposit_requests;
CREATE POLICY "Service role manages deposit requests"
  ON deposit_requests FOR ALL TO service_role USING (true) WITH CHECK (true);

-- No INSERT policy for players, deliberately. Claims are created through the
-- API, which derives player_id from the verified token. A direct insert would
-- let a player file a claim as somebody else -- the same defect
-- services/functions/src/select-card.js exists to remove.

-- ---------------------------------------------------------------------------
-- A decided request is IMMUTABLE
--
-- The row is the audit record. Without this, an approved request can be set back
-- to pending and approved again, and the second credit looks exactly like the
-- first. The idempotency in approve_deposit_request() depends on a decided row
-- staying decided; this is what makes that true even against a direct UPDATE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION deposit_requests_freeze_decided()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'pending' THEN
    RAISE EXCEPTION
      'deposit request % is already %; a decided request cannot be changed',
      OLD.id, OLD.status
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS deposit_requests_no_redecide ON deposit_requests;
CREATE TRIGGER deposit_requests_no_redecide
  BEFORE UPDATE ON deposit_requests
  FOR EACH ROW EXECUTE FUNCTION deposit_requests_freeze_decided();

-- ---------------------------------------------------------------------------
-- Approving credits, exactly once
--
-- The WHERE clause is the lock. `status = 'pending'` inside the UPDATE means two
-- concurrent approvals contend on the row, and the loser updates zero rows and
-- returns already_decided rather than crediting a second time. There is no
-- read-then-write window to lose.
--
-- Credits deposited_balance, NOT won_balance: deposits are not withdrawable in
-- this system (20251217172433), and crediting the wrong column would turn every
-- deposit into a cash-out route. `balance` is left alone -- sync_total_balance()
-- is a BEFORE trigger that recomputes it from the two components, so writing it
-- here would either be redundant or fight the trigger.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_deposit_request(
  p_request_id uuid,
  p_actual_amount integer,
  p_admin_id uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row deposit_requests%ROWTYPE;
BEGIN
  IF p_actual_amount IS NULL OR p_actual_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'INVALID_AMOUNT');
  END IF;

  IF p_admin_id IS NULL THEN
    -- Belt and braces: the route checks requireAdmin, but a decision with no
    -- decider is worse than a refused one.
    RETURN jsonb_build_object('success', false, 'error_code', 'NO_ADMIN');
  END IF;

  UPDATE deposit_requests
     SET status          = 'approved',
         credited_amount = p_actual_amount,
         decided_by      = p_admin_id,
         decided_at      = now(),
         admin_note      = p_note
   WHERE id = p_request_id
     AND status = 'pending'
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    -- Either it does not exist or somebody already decided it. Both mean "do not
    -- credit", and the caller does not need to be told which.
    RETURN jsonb_build_object('success', false, 'error_code', 'NOT_PENDING');
  END IF;

  -- Names this movement in the balance ledger (db/20-post/019). Transaction-
    -- local, so it cannot leak into the next statement on a pooled connection.
  PERFORM set_config('app.ledger_reason', 'deposit_approval', true);

  UPDATE telegram_users
     SET deposited_balance = COALESCE(deposited_balance, 0) + p_actual_amount,
         total_deposited   = COALESCE(total_deposited, 0) + p_actual_amount
   WHERE id = v_row.player_id;

  RETURN jsonb_build_object(
    'success', true,
    'request_id', v_row.id,
    'player_id', v_row.player_id,
    'credited', p_actual_amount,
    'claimed', v_row.claimed_amount
  );
END;
$$;

CREATE OR REPLACE FUNCTION reject_deposit_request(
  p_request_id uuid,
  p_admin_id uuid,
  p_note text DEFAULT NULL
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

  UPDATE deposit_requests
     SET status     = 'rejected',
         decided_by = p_admin_id,
         decided_at = now(),
         admin_note = p_note
   WHERE id = p_request_id
     AND status = 'pending'
  RETURNING id INTO v_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'NOT_PENDING');
  END IF;

  RETURN jsonb_build_object('success', true, 'request_id', v_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- EXECUTE stays with service_role only
--
-- db/20-post/004 made EXECUTE an allowlist. These take an admin id as a
-- parameter and do not verify it, exactly like the money functions 004 revoked
-- -- so exposing them to `authenticated` would let any player approve their own
-- deposit by naming themselves. They are called only by the admin routes, which
-- connect as app_service and check requireAdmin first.
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION approve_deposit_request(uuid, integer, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION reject_deposit_request(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION approve_deposit_request(uuid, integer, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION reject_deposit_request(uuid, uuid, text) TO service_role;

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'approve_deposit_request(uuid,integer,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'approve_deposit_request is callable by authenticated; a player could approve their own deposit.';
  END IF;
  RAISE NOTICE 'deposit approval: service_role only';
END $$;
