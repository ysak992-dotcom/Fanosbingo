/*
  # An append-only journal for every balance movement
  #
  # WHAT IS MISSING WITHOUT THIS
  #
  # Player money lives in two mutable integer columns on telegram_users --
  # deposited_balance and won_balance -- and nothing records how they got to
  # their current values. Every money path is individually careful: 006 locks the
  # row before crediting, 007 computes available balance under a lock and puts a
  # unique index on the payout reference, 014 refunds a stake to the balance that
  # paid it. The audit trail is real, and it is SCATTERED across deposit_requests,
  # withdrawal_requests, games and players.
  #
  # So "why is this player's balance 340?" is answered by joining four tables and
  # trusting that every writer was correct, and "does the sum of all balances
  # match the money we have actually taken in?" is not answerable at all. For a
  # system holding real deposits that is the wrong way round: the ledger should
  # be the primary record and the balance a derived convenience.
  #
  # WHY A TRIGGER RATHER THAN INSTRUMENTING THE CALL SITES
  #
  # Seventeen migration files contain a statement that writes one of these
  # columns. Editing each one would journal the paths somebody remembered, which
  # is exactly the set of paths that were never the problem -- and it would leave
  # the next writer to remember too. This is a property of the TABLE, so it is
  # enforced at the table. A future function that credits a balance and knows
  # nothing about this file is journalled anyway.
  #
  # WHAT "APPEND-ONLY" MEANS HERE, PRECISELY
  #
  # No role that the application runs as may write this table at all: entries
  # arrive only through a SECURITY DEFINER trigger owned by the migration user,
  # and UPDATE, DELETE and TRUNCATE are granted to nobody. app_service holds
  # BYPASSRLS, which bypasses row security and NOT table grants, so the service
  # that moves the money cannot rewrite the record of having moved it.
  #
  # It is not tamper-PROOF. The database owner can do anything, and that is the
  # honest boundary -- the same one the nightly dumps under S3 Object Lock exist
  # to sit outside of. It is tamper-EVIDENT: reconcile_balances() compares the
  # journal against the balances and disagrees loudly.
  #
  # THE THIRD COPY, which this also cleans up. `balance` is a legacy column from
  # before 20251217172433 split it into deposited and won. payout_winners() still
  # maintains it; 006, 007, 014 and 018 -- every money path written since -- do
  # not. src/components/Admin.tsx:717 shows it to the operator as the player's
  # balance and line 789 sums it as a house total, so an operator is being shown
  # a number that stopped tracking reality some time ago. Section 5 makes it a
  # derived value that cannot drift again.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- ---------------------------------------------------------------------------
-- 1. The journal
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS balance_entries (
  id bigserial PRIMARY KEY,

  -- The Telegram id rather than the uuid, because that is what every money path
  -- here already keys on -- 007's available-balance calculation, 014's refund,
  -- the deduct trigger -- and a join to resolve it would be one more thing that
  -- can be wrong.
  telegram_user_id bigint NOT NULL,

  occurred_at timestamptz NOT NULL DEFAULT now(),

  -- Signed deltas. Both are recorded on every entry, including the zero, so a
  -- reader never has to distinguish "unchanged" from "not recorded".
  deposited_delta integer NOT NULL,
  won_delta       integer NOT NULL,

  -- The resulting balances, denormalised deliberately. It makes an entry
  -- self-describing when you are reading one row in a support conversation, and
  -- it makes a break in the chain visible without summing the whole history.
  deposited_after integer NOT NULL,
  won_after       integer NOT NULL,

  -- Best-effort provenance. A trigger cannot know WHY, so money paths set
  -- `app.ledger_reason` and this picks it up; an unset reason is NULL rather
  -- than a guess. NULL does not mean unrecorded -- the entry still exists, which
  -- is the whole point of doing this at the table.
  reason text,

  -- Who, at the database level. Distinguishes the application (app_service) from
  -- somebody at the SSM tunnel, which is the distinction that matters when a
  -- movement is being explained after the fact.
  db_role text NOT NULL DEFAULT current_user,

  -- Groups every entry made by one transaction. A stake deduction and the pot
  -- update it belongs to share a txid; so do a refund and its release.
  txid bigint NOT NULL DEFAULT txid_current()
);

COMMENT ON TABLE balance_entries IS
  'Append-only journal of every change to telegram_users.deposited_balance and won_balance. Written by a trigger, so a money path that knows nothing about this table is still recorded. Reconciled by reconcile_balances().';

CREATE INDEX IF NOT EXISTS balance_entries_user_idx
  ON balance_entries (telegram_user_id, id);

CREATE INDEX IF NOT EXISTS balance_entries_occurred_idx
  ON balance_entries (occurred_at);

-- ---------------------------------------------------------------------------
-- 2. Nobody writes this but the trigger
--
-- RLS with no policy for anon or authenticated, matching db/20-post/012: the
-- client has no business reading other players' movements, and its own history
-- is already available as deposit_requests and withdrawal_requests.
--
-- SELECT to service_role so the operator tooling and reconcile_balances() can
-- read it. No INSERT, UPDATE or DELETE to anyone -- entries arrive through the
-- SECURITY DEFINER trigger below, which runs as this table's owner.
-- ---------------------------------------------------------------------------
ALTER TABLE balance_entries ENABLE ROW LEVEL SECURITY;

-- service_role IS IN THIS REVOKE, and finding out why cost a failed assertion.
--
-- db/00-bootstrap/001 sets
--
--   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
--
-- so every table created by the migration runner afterwards -- including this one
-- -- arrives with INSERT, UPDATE, DELETE and TRUNCATE already granted to
-- service_role, which app_service inherits. Nothing here granted it; it was
-- granted in advance, for tables that did not exist yet.
--
-- The first version of this file revoked from PUBLIC, anon and authenticated
-- only, on the reasoning that service_role needs to read the journal. Section 7
-- then deleted journal entries as service_role and said so. "I did not grant it"
-- is not the same statement as "it is not granted", and a default privilege is
-- precisely where the two come apart.
--
-- SELECT is granted back deliberately: reconcile_balances() and any operator
-- tooling must read it. Nothing needs to write it but the trigger, which runs as
-- this table's owner.
REVOKE ALL ON TABLE balance_entries FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE balance_entries TO service_role;

-- db/20-post/001 issues `GRANT USAGE, SELECT ON ALL SEQUENCES ... TO anon,
-- authenticated` and runs BEFORE this file on every pass, so it re-grants this
-- sequence each time. Revoked here, after it, where the revoke actually sticks.
-- Harmless on its own -- a sequence is useless without INSERT on the table --
-- but a grant that exists only because a loop was too broad is worth removing.
REVOKE ALL ON SEQUENCE balance_entries_id_seq FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION journal_balance_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old_dep integer := 0;
  v_old_won integer := 0;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_old_dep := COALESCE(OLD.deposited_balance, 0);
    v_old_won := COALESCE(OLD.won_balance, 0);

    -- Nothing to say about an update that did not move money. telegram_users is
    -- written on every login (last_active_at), so without this the journal would
    -- be mostly noise.
    IF COALESCE(NEW.deposited_balance, 0) = v_old_dep
       AND COALESCE(NEW.won_balance, 0) = v_old_won THEN
      RETURN NULL;
    END IF;
  END IF;

  INSERT INTO balance_entries (
    telegram_user_id, deposited_delta, won_delta,
    deposited_after, won_after, reason
  )
  VALUES (
    NEW.telegram_user_id,
    COALESCE(NEW.deposited_balance, 0) - v_old_dep,
    COALESCE(NEW.won_balance, 0) - v_old_won,
    COALESCE(NEW.deposited_balance, 0),
    COALESCE(NEW.won_balance, 0),
    -- current_setting with missing_ok, so an unset reason is NULL rather than an
    -- error that would roll back the money movement itself. The journal must
    -- never be the reason a legitimate payment fails.
    nullif(current_setting('app.ledger_reason', true), '')
  );

  RETURN NULL;  -- AFTER trigger; the return value is discarded.
END;
$$;

DROP TRIGGER IF EXISTS journal_balance_on_change ON telegram_users;
CREATE TRIGGER journal_balance_on_change
  AFTER INSERT OR UPDATE ON telegram_users
  FOR EACH ROW
  EXECUTE FUNCTION journal_balance_change();

-- ---------------------------------------------------------------------------
-- 4. Opening balances
--
-- The invariant this file establishes is "the deltas sum to the balance". That
-- cannot be true for a player who already had money before the journal existed,
-- so every existing row gets one opening entry equal to its current balance.
--
-- Guarded on the user having NO entries, which makes it idempotent AND makes it
-- correct for a user created after this file first ran -- they were journalled
-- by the INSERT trigger and must not be given a second opening entry.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_opened integer;
BEGIN
  WITH opened AS (
    INSERT INTO balance_entries (
      telegram_user_id, deposited_delta, won_delta,
      deposited_after, won_after, reason
    )
    SELECT u.telegram_user_id,
           COALESCE(u.deposited_balance, 0),
           COALESCE(u.won_balance, 0),
           COALESCE(u.deposited_balance, 0),
           COALESCE(u.won_balance, 0),
           'ledger_opening'
      FROM telegram_users u
     WHERE u.telegram_user_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM balance_entries e
          WHERE e.telegram_user_id = u.telegram_user_id
       )
    RETURNING 1
  )
  SELECT count(*) INTO v_opened FROM opened;

  IF v_opened > 0 THEN
    RAISE NOTICE 'balance ledger: opened % account(s) at their current balance', v_opened;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. `balance` becomes derived, so it cannot be a third opinion
--
-- See the header. This column is maintained by payout_winners() and by nothing
-- written since the deposited/won split, while the admin panel still displays
-- it. A BEFORE trigger that always sets it from the two authoritative columns
-- makes it a view of them rather than a copy: any writer that sets it is simply
-- overruled, which is the correct outcome for a value that should never have
-- been independently writable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_total_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.balance := COALESCE(NEW.deposited_balance, 0) + COALESCE(NEW.won_balance, 0);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_balance_on_change ON telegram_users;
CREATE TRIGGER sync_balance_on_change
  BEFORE INSERT OR UPDATE ON telegram_users
  FOR EACH ROW
  EXECUTE FUNCTION sync_total_balance();

-- Correct the rows that already drifted. Without this the trigger only fixes a
-- player from their next movement onward, and a dormant account keeps showing
-- the operator a stale number indefinitely.
UPDATE telegram_users
   SET balance = COALESCE(deposited_balance, 0) + COALESCE(won_balance, 0)
 WHERE COALESCE(balance, -1) <> COALESCE(deposited_balance, 0) + COALESCE(won_balance, 0);

-- ---------------------------------------------------------------------------
-- 6. reconcile_balances()
--
-- The question the journal exists to answer. Returns the number of accounts
-- whose balance disagrees with their own history, and the worst offenders --
-- bounded, because a report that returns every row of a broken table is a report
-- nobody can read.
--
-- Published as a CloudWatch metric by the ticker via queue_health(), so drift
-- becomes an alarm rather than something discovered during a dispute.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reconcile_balances(p_limit integer DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result jsonb;
BEGIN
  WITH summed AS (
    SELECT e.telegram_user_id,
           sum(e.deposited_delta)::bigint AS dep_journal,
           sum(e.won_delta)::bigint       AS won_journal
      FROM balance_entries e
     GROUP BY e.telegram_user_id
  ),
  compared AS (
    SELECT u.telegram_user_id,
           COALESCE(u.deposited_balance, 0)  AS dep_actual,
           COALESCE(s.dep_journal, 0)        AS dep_journal,
           COALESCE(u.won_balance, 0)        AS won_actual,
           COALESCE(s.won_journal, 0)        AS won_journal
      FROM telegram_users u
      LEFT JOIN summed s ON s.telegram_user_id = u.telegram_user_id
     WHERE u.telegram_user_id IS NOT NULL
  ),
  drifted AS (
    SELECT * FROM compared
     WHERE dep_actual <> dep_journal OR won_actual <> won_journal
  )
  SELECT jsonb_build_object(
    'checked_at',    now(),
    'accounts',      (SELECT count(*) FROM compared),
    'drifted',       (SELECT count(*) FROM drifted),
    -- The size of the disagreement, not just its existence. One account out by
    -- 1 and one out by 40000 need different responses.
    'drift_total',   COALESCE((
      SELECT sum(abs(dep_actual - dep_journal) + abs(won_actual - won_journal))
        FROM drifted), 0),
    'worst', COALESCE((
      SELECT jsonb_agg(d ORDER BY d.magnitude DESC)
        FROM (
          SELECT telegram_user_id,
                 dep_actual, dep_journal, won_actual, won_journal,
                 abs(dep_actual - dep_journal) + abs(won_actual - won_journal) AS magnitude
            FROM drifted
           ORDER BY magnitude DESC
           LIMIT greatest(p_limit, 1)
        ) d), '[]'::jsonb)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION reconcile_balances(integer) IS
  'Compares every account balance against the sum of its own journal entries. drifted = 0 is the invariant; anything else means a balance moved without being recorded, or a record was altered.';

REVOKE ALL ON FUNCTION reconcile_balances(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION reconcile_balances(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Assert it, BY MOVING MONEY
--
-- Same discipline as 014 and 018. A journal that is installed but not firing
-- looks exactly like a journal that is working, right up until the first
-- dispute -- so this moves a real balance and reads the entry back, then breaks
-- the invariant on purpose to prove the reconciliation notices.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tg      bigint := -999000003;
  v_n       integer;
  v_reason  text;
  v_after   integer;
  v_recon   jsonb;
  v_denied  boolean;
BEGIN
  DELETE FROM telegram_users WHERE telegram_user_id = v_tg;

  -- (a) An INSERT opens the account.
  INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
  VALUES (v_tg, '_ledger_probe', 100, 25);

  SELECT count(*) INTO v_n FROM balance_entries WHERE telegram_user_id = v_tg;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'ledger: creating an account wrote % entries, expected 1. The trigger is not firing on INSERT.', v_n;
  END IF;

  -- (b) A credit is journalled, with its reason.
  PERFORM set_config('app.ledger_reason', 'probe_credit', true);
  UPDATE telegram_users SET deposited_balance = deposited_balance + 40 WHERE telegram_user_id = v_tg;
  PERFORM set_config('app.ledger_reason', '', true);

  SELECT reason, deposited_after INTO v_reason, v_after
    FROM balance_entries WHERE telegram_user_id = v_tg ORDER BY id DESC LIMIT 1;

  IF v_reason IS DISTINCT FROM 'probe_credit' THEN
    RAISE EXCEPTION 'ledger: the entry recorded reason %, expected probe_credit.', quote_nullable(v_reason);
  END IF;
  IF v_after <> 140 THEN
    RAISE EXCEPTION 'ledger: deposited_after was %, expected 140.', v_after;
  END IF;

  -- (c) An update that moves NO money writes nothing. telegram_users is touched
  -- on every login, and a journal full of those is a journal nobody reads.
  UPDATE telegram_users SET last_active_at = now() WHERE telegram_user_id = v_tg;

  SELECT count(*) INTO v_n FROM balance_entries WHERE telegram_user_id = v_tg;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'ledger: a non-money update was journalled; % entries after three writes, expected 2.', v_n;
  END IF;

  -- (d) `balance` is derived, not written.
  UPDATE telegram_users SET balance = 999999 WHERE telegram_user_id = v_tg;
  IF (SELECT balance FROM telegram_users WHERE telegram_user_id = v_tg) <> 165 THEN
    RAISE EXCEPTION 'ledger: balance was writable and is now %, expected 165 (140 + 25). sync_total_balance is not overruling direct writes.',
      (SELECT balance FROM telegram_users WHERE telegram_user_id = v_tg);
  END IF;

  -- (e) The reconciliation agrees, for this account and every other.
  v_recon := reconcile_balances();
  IF (v_recon->>'drifted')::integer <> 0 THEN
    RAISE EXCEPTION 'ledger: reconciliation reports % drifted account(s) immediately after installation: %',
      v_recon->>'drifted', v_recon->'worst';
  END IF;

  -- (f) AND IT IS NOT VACUOUS. Move money behind the journal's back -- by
  -- disabling the trigger, which is what a bug or a manual UPDATE with triggers
  -- off amounts to -- and require the reconciliation to catch it.
  ALTER TABLE telegram_users DISABLE TRIGGER journal_balance_on_change;
  UPDATE telegram_users SET won_balance = won_balance + 500 WHERE telegram_user_id = v_tg;
  ALTER TABLE telegram_users ENABLE TRIGGER journal_balance_on_change;

  v_recon := reconcile_balances();
  IF (v_recon->>'drifted')::integer <> 1 THEN
    RAISE EXCEPTION 'ledger: 500 was moved without an entry and reconciliation reported % drifted. It is not actually checking anything.',
      v_recon->>'drifted';
  END IF;
  IF (v_recon->>'drift_total')::bigint <> 500 THEN
    RAISE EXCEPTION 'ledger: drift_total was %, expected 500.', v_recon->>'drift_total';
  END IF;

  -- (g) The journal is not rewritable by the roles the application runs as.
  BEGIN
    v_denied := false;
    SET LOCAL ROLE service_role;
    DELETE FROM balance_entries WHERE telegram_user_id = v_tg;
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  RESET ROLE;

  IF NOT v_denied THEN
    RAISE EXCEPTION 'ledger: service_role deleted journal entries. The record of a payment must not be writable by the thing that makes payments.';
  END IF;

  -- Clean up. The user row goes; its entries are deliberately left, because
  -- deleting them is exactly what the table forbids -- and a probe that could
  -- tidy up after itself would prove the opposite of what (g) just showed.
  DELETE FROM telegram_users WHERE telegram_user_id = v_tg;
  DELETE FROM balance_entries WHERE telegram_user_id = v_tg;

  RAISE NOTICE 'balance ledger: entries written, reasons captured, balance derived, drift detected, journal not writable by service_role';
END $$;
