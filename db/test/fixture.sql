/*
  # A production-shaped schema, small enough to build in CI in a second.
  #
  # WHY THIS EXISTS. Nothing in CI executed migration SQL. `db-migrate.yml`'s
  # pull-request job runs `db-migrate.sh --dry-run`, which prints filenames and
  # `continue`s -- it never runs them -- and the `migrations` job in test.yml is a
  # static check over CREATE/DROP statements. Both reported success on a pull
  # request adding two migrations without executing either.
  #
  # So a syntax error, an unsatisfiable constraint or a failing assertion would
  # have merged green. The only thing standing between that and production was
  # somebody remembering to run psql by hand.
  #
  # WHY A FIXTURE RATHER THAN REPLAYING ALL 110 MIGRATIONS.
  #
  # db/00-bootstrap/001 asserts `wal_level = logical` and pg_cron in
  # shared_preload_libraries -- correctly, because Realtime silently delivers
  # nothing without the first and the game loop was moved off pg_cron because of
  # the second. Neither is available in a stock `postgres:16` service container,
  # so a full replay needs a custom image before it needs anything else.
  #
  # This builds the objects `db/20-post/001` onwards actually touch, which is
  # where every security decision in this repository lives. It is not a
  # substitute for the migration run against dev; it is the check that catches the
  # class of mistake that has actually happened here -- a migration that does not
  # apply, or an assertion that does not hold.
  #
  # IF IT DRIFTS FROM PRODUCTION, THE JOB FAILS. That is the right direction: a
  # missing column here is a loud CI failure rather than a quiet gap in coverage.
  #
  # 001 AND 002 ARE NO LONGER SKIPPED. The paragraph above used to end by
  # explaining that a full replay "needs a custom image before it needs anything
  # else" -- and then the harness skipped the two files that needed one. That
  # left game_tick(), which starts games, calls numbers, closes claim windows and
  # fires the payout trigger, as the only money-moving code here with no
  # automated coverage whatsoever. db/test/Dockerfile is the custom image; this
  # file now builds what those two need as well.
*/

-- ---------------------------------------------------------------------------
-- Extensions, as db/00-bootstrap/001 creates them.
--
-- pg_cron is what db/20-post/001 unschedules the 4-second game loop from, and
-- pgcrypto is what secure_random_int() draws bingo numbers from. Both must be
-- present BEFORE the migrations run, and pg_cron additionally requires the
-- server to have been STARTED with it in shared_preload_libraries -- which is
-- why scripts/test-migrations.sh passes that as a server argument and why the
-- stock image could not host this.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Roles, as db/00-bootstrap/001 creates them.
CREATE ROLE anon NOLOGIN NOINHERIT;
CREATE ROLE authenticated NOLOGIN NOINHERIT;
CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD 'fixture';
CREATE ROLE app_service LOGIN INHERIT PASSWORD 'fixture';
GRANT anon, authenticated, service_role TO authenticator;
GRANT service_role TO app_service;
-- The attribute, which membership does not carry. Without this line the
-- assertion in 004 correctly fails, which is how the real bug was found.
ALTER ROLE app_service BYPASSRLS;

CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid
$$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '')::text
$$;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.role() TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE telegram_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  telegram_user_id bigint UNIQUE,
  telegram_username text,
  telegram_first_name text,
  telegram_last_name text,
  balance integer DEFAULT 0,
  deposited_balance integer DEFAULT 0,
  won_balance integer DEFAULT 0,
  total_deposited integer DEFAULT 0,
  total_spent integer DEFAULT 0,
  total_won integer DEFAULT 0,
  -- 20251213155759. Written by payout_winners() on every win, so its absence
  -- here made the payout path fail the moment the harness started executing it.
  win_count integer DEFAULT 0,
  total_withdrawn numeric DEFAULT 0,
  referral_code text,
  total_referrals integer DEFAULT 0,
  wallet_address text UNIQUE,
  last_active_at timestamptz DEFAULT now(),
  created_at timestamptz DEFAULT now()
);
ALTER TABLE telegram_users ENABLE ROW LEVEL SECURITY;

-- The permissive policies db/20-post/004 exists to remove. Present so the
-- migration is exercised against the state it was written for rather than
-- against an already-clean database, where its DROP loop would be a no-op.
CREATE POLICY "Anon users can read telegram_users for lobby"
  ON telegram_users FOR SELECT TO anon, public USING (true);
CREATE POLICY "Service role can manage telegram users"
  ON telegram_users FOR ALL TO service_role USING (true) WITH CHECK (true);

-- `balance` is maintained by a trigger, so nothing may write it directly.
CREATE OR REPLACE FUNCTION sync_total_balance() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.balance := COALESCE(NEW.deposited_balance,0) + COALESCE(NEW.won_balance,0); RETURN NEW; END $$;
CREATE TRIGGER sync_balance_on_change BEFORE INSERT OR UPDATE ON telegram_users
  FOR EACH ROW EXECUTE FUNCTION sync_total_balance();

CREATE TABLE settings (
  id text PRIMARY KEY,
  value text,
  description text,
  updated_at timestamptz DEFAULT now(),
  updated_by text
);
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read settings" ON settings FOR SELECT TO public USING (true);
CREATE POLICY "Service role can manage settings" ON settings FOR ALL TO service_role USING (true) WITH CHECK (true);
INSERT INTO settings (id, value) VALUES
  ('telegram_bot_token', 'a-secret-that-must-be-redacted'),
  ('sms_api_key', 'another-secret'),
  ('commission_rate', '20'),
  ('deposit_contract_address', ''),
  ('deposit_contract_chain_id', '97');

-- total_pot and winner_prize carry DEFAULT 0 in production (20251110051255).
-- They were bare here, so a game inserted without them started at NULL and the
-- pot arithmetic in db/20-post/018 had nothing to add to -- the same class of
-- fixture-laxer-than-production problem as the NOT NULLs on `players` below.
-- The remaining columns are the ones game_tick() drives the state machine
-- through: the claim window it closes, the call clock it advances, the
-- selection cutoff it rolls, and the winner fields payout_winners() reads.
CREATE TABLE games (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_number integer, status text, total_pot integer DEFAULT 0, stake_amount integer DEFAULT 10,
  winner_prize integer DEFAULT 0, called_numbers integer[] DEFAULT '{}',
  starts_at timestamptz DEFAULT now(), created_at timestamptz DEFAULT now(),
  host_id text,
  current_number integer,
  last_number_called_at timestamptz,
  selection_closed_at timestamptz,
  claim_window_start timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  winner_ids uuid[] DEFAULT '{}',
  winner_prize_each integer DEFAULT 0,
  winners_paid boolean DEFAULT false
);
ALTER TABLE games ENABLE ROW LEVEL SECURITY;
CREATE POLICY g_read ON games FOR SELECT TO anon, authenticated USING (true);

-- name and card are NOT NULL on the real table (20251109203131). They were
-- nullable here, which let db/20-post/014's probe pass the harness and then fail
-- the first real apply. A fixture that is laxer than production tests nothing
-- about the constraints production actually has.
CREATE TABLE players (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id uuid NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  name text NOT NULL,
  card jsonb NOT NULL,
  selected_number integer, telegram_user_id bigint,
  card_numbers jsonb, marked_cells jsonb, is_disqualified boolean DEFAULT false
);
ALTER TABLE players ENABLE ROW LEVEL SECURITY;

-- The stake pair, in their INHERITED form -- the splitting deduction from
-- 20260725000000 and the all-to-deposited refund from 20251225111615.
--
-- Present for the same reason the blanket grants above are: so db/20-post/014
-- has something to replace. Without them a join-and-release probe inserts a row,
-- deletes it, observes nothing happen, and passes -- which is the third variant
-- of the vacuous-assertion trap 003 and 004 document, and the one that would
-- have shipped a money fix proven by a test that exercised no money code.
CREATE OR REPLACE FUNCTION deduct_stake_from_balance()
RETURNS TRIGGER SECURITY DEFINER SET search_path=public LANGUAGE plpgsql AS $$
DECLARE s integer; d integer; w integer; fd integer; fw integer;
BEGIN
  SELECT stake_amount INTO s FROM games WHERE id = NEW.game_id;
  IF s IS NULL THEN RAISE EXCEPTION 'Game not found'; END IF;
  SELECT COALESCE(deposited_balance,0), COALESCE(won_balance,0) INTO d, w
    FROM telegram_users WHERE telegram_user_id = NEW.telegram_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'User % not found', NEW.telegram_user_id; END IF;
  IF d + w < s THEN
    RAISE EXCEPTION 'INSUFFICIENT_BALANCE: stake % exceeds available balance %', s, d + w
      USING ERRCODE = 'check_violation';
  END IF;
  IF d >= s THEN fd := s; fw := 0; ELSE fd := d; fw := s - d; END IF;
  UPDATE telegram_users
     SET deposited_balance = deposited_balance - fd,
         won_balance = won_balance - fw,
         total_spent = COALESCE(total_spent,0) + s
   WHERE telegram_user_id = NEW.telegram_user_id;
  RETURN NEW;
END $$;

CREATE TRIGGER deduct_stake_on_join BEFORE INSERT ON players
  FOR EACH ROW EXECUTE FUNCTION deduct_stake_from_balance();

CREATE OR REPLACE FUNCTION refund_player_stake()
RETURNS TRIGGER SECURITY DEFINER SET search_path=public LANGUAGE plpgsql AS $$
DECLARE s integer;
BEGIN
  IF OLD.telegram_user_id IS NULL THEN RETURN OLD; END IF;
  SELECT stake_amount INTO s FROM games WHERE id = OLD.game_id;
  IF s IS NULL THEN RETURN OLD; END IF;
  -- Everything to deposited_balance, which is the bug db/20-post/014 fixes.
  UPDATE telegram_users
     SET deposited_balance = deposited_balance + s,
         total_spent = GREATEST(0, COALESCE(total_spent,0) - s)
   WHERE telegram_user_id = OLD.telegram_user_id;
  RETURN OLD;
END $$;

CREATE TRIGGER refund_on_player_delete BEFORE DELETE ON players
  FOR EACH ROW EXECUTE FUNCTION refund_player_stake();

-- The pot half of the same pair, in its INHERITED form (20251227082804), and
-- present for the same reason: so db/20-post/018 has something to replace.
--
-- Reproduced with its two defects intact, because they are what 018 asserts
-- against:
--
--   * the COALESCE is INSIDE the query, so a MISSING settings row yields NULL
--     rather than 20 -- and winner_prize then becomes NULL
--   * no `IF ... IS NULL` guard after the read, unlike refund_player_stake()
--
-- Writing the FIXED version here would make 018's probe pass against code 018
-- did not produce, which is the vacuity trap this file already documents twice.
CREATE OR REPLACE FUNCTION update_game_pot()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE commission_rate_val integer;
BEGIN
  SELECT COALESCE(value::integer, 20) INTO commission_rate_val
    FROM settings WHERE id = 'commission_rate';
  UPDATE games
     SET total_pot = total_pot + stake_amount,
         winner_prize = FLOOR((total_pot + stake_amount) * (100 - commission_rate_val) / 100)
   WHERE id = NEW.game_id;
  RETURN NEW;
END $$;

CREATE TRIGGER update_pot_on_player_join AFTER INSERT ON players
  FOR EACH ROW EXECUTE FUNCTION update_game_pot();

-- The payout trigger, as 20251218160619 defines it.
--
-- Present because game_tick() finishing a game is what FIRES it: closing an
-- expired claim window sets status='finished', and everything a winner is
-- actually paid happens in here. Testing the loop without this would test that
-- a status column changes value, which is not the part that costs money.
--
-- Reproduced faithfully, including `winners_paid` guarding against double
-- payment -- that guard is one of the things db/test/game_tick_test.sql asserts.
CREATE OR REPLACE FUNCTION payout_winners()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE w uuid; prize integer;
BEGIN
  IF NEW.status = 'finished' AND NEW.winners_paid = false
     AND NEW.winner_ids IS NOT NULL AND array_length(NEW.winner_ids, 1) > 0 THEN
    prize := NEW.winner_prize_each;
    FOREACH w IN ARRAY NEW.winner_ids LOOP
      UPDATE telegram_users tu
         SET won_balance = COALESCE(tu.won_balance,0) + prize,
             total_won   = COALESCE(tu.total_won,0) + prize,
             win_count   = COALESCE(tu.win_count,0) + 1
        FROM players p
       WHERE p.id = w AND p.telegram_user_id = tu.telegram_user_id;
    END LOOP;
    NEW.winners_paid = true;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER payout_on_game_finish BEFORE UPDATE ON games
  FOR EACH ROW WHEN (NEW.status = 'finished' AND OLD.status <> 'finished')
  EXECUTE FUNCTION payout_winners();

-- ---------------------------------------------------------------------------
-- What db/20-post/001 needs beyond the tables
--
-- The publication it asserts covers games and players, and the four cleanup
-- functions it schedules. cron.schedule() stores its command as text without
-- parsing it, so the bodies are irrelevant -- but the publication assertion is
-- a real check of a real failure (Realtime connecting and silently delivering
-- nothing), so the publication is built properly rather than stubbed.
-- ---------------------------------------------------------------------------
CREATE PUBLICATION supabase_realtime FOR TABLE games, players;

CREATE FUNCTION cleanup_old_game_events()  RETURNS void LANGUAGE sql AS $$ SELECT $$;
CREATE FUNCTION cleanup_old_snapshots()    RETURNS void LANGUAGE sql AS $$ SELECT $$;
CREATE FUNCTION cleanup_old_user_states()  RETURNS void LANGUAGE sql AS $$ SELECT $$;
CREATE FUNCTION expire_old_pending_sms()   RETURNS void LANGUAGE sql AS $$ SELECT $$;

CREATE TABLE bank_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bank_name text NOT NULL, account_number text NOT NULL, account_name text,
  instructions text NOT NULL, is_active boolean DEFAULT true, display_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now()
);


CREATE TABLE withdrawal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  telegram_user_id bigint NOT NULL REFERENCES telegram_users(telegram_user_id) ON DELETE CASCADE,
  amount numeric(10,2) NOT NULL CHECK (amount > 0),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','completed','rejected')),
  requested_at timestamptz DEFAULT now() NOT NULL,
  processed_at timestamptz, processed_by_admin text, rejection_reason text,
  bank_name text NOT NULL, account_number text NOT NULL, account_name text NOT NULL,
  admin_notes text
);
ALTER TABLE withdrawal_requests ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION get_available_balance(user_telegram_id bigint) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
DECLARE w numeric; p numeric;
BEGIN
  SELECT won_balance INTO w FROM telegram_users WHERE telegram_user_id=user_telegram_id;
  IF w IS NULL THEN RETURN 0; END IF;
  SELECT COALESCE(sum(amount),0) INTO p FROM withdrawal_requests
    WHERE telegram_user_id=user_telegram_id AND status IN ('pending','processing');
  RETURN w - p;
END $fn$;

CREATE TABLE card_layouts (
  card_number integer PRIMARY KEY,
  layout jsonb NOT NULL
);

-- ---------------------------------------------------------------------------
-- Functions 20-post grants, revokes or replaces. Bodies are stubs except where
-- a migration replaces them wholesale.
-- ---------------------------------------------------------------------------
CREATE FUNCTION transfer_balance(from_telegram_id bigint, transfer_amount integer, to_telegram_id bigint, balance_type_param text DEFAULT 'won')
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION process_bnb_withdrawal_request(p_telegram_user_id bigint, p_wallet_address text, p_amount_bnb numeric, p_signature text, p_nonce text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION record_user_withdrawal(p_telegram_user_id bigint, p_wallet_address text, p_amount_bnb numeric, p_transaction_hash text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION select_card_atomic(p_game_id uuid, p_card_number integer, p_telegram_user_id bigint, p_player_name text,
  p_card jsonb DEFAULT NULL, p_card_numbers jsonb DEFAULT NULL, p_marked_cells jsonb DEFAULT NULL,
  p_telegram_username text DEFAULT NULL, p_telegram_first_name text DEFAULT NULL, p_telegram_last_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION atomic_claim_bingo(p_player_id uuid, p_claim_window_ms integer DEFAULT 1000)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION handle_referral_bonus(new_user_telegram_id bigint, referrer_code text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION check_bnb_withdrawal_limits(p_telegram_user_id bigint, p_amount_bnb numeric)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION payout_winners(p_game_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN END $$;
CREATE FUNCTION get_server_timestamp_ms() RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT 0::bigint $$;
CREATE FUNCTION get_or_create_wallet_user(p_wallet_address text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION get_or_create_card_layout(p_card_number integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION get_all_card_layouts()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION get_card_layouts_batch(p_card_numbers integer[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION create_game_with_server_time()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION get_bnb_withdrawal_stats()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
-- NO game_tick STUB. db/20-post/002 now runs against this fixture and defines
-- the real five-argument function itself.
--
-- The stub that used to be here took THREE arguments, so once 002 stopped being
-- skipped both signatures existed and 002's own
-- `REVOKE ALL ON FUNCTION game_tick` -- unqualified -- failed with
--
--   ERROR: function name "game_tick" is not unique
--
-- which is precisely the failure scripts/check-migrations.mjs was written about,
-- arriving from the fixture rather than from a migration. 002 now names its
-- argument types; this stub is deleted rather than corrected, because a stub
-- shadowing the real thing is what made the harness able to disagree with
-- production in the first place.

-- The stale one-argument overload db/20-post/004 drops. Present so that DROP is
-- exercised rather than skipped.
CREATE FUNCTION get_lobby_data_instant(user_telegram_id bigint DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION get_lobby_data_instant(user_telegram_id bigint DEFAULT NULL, user_wallet_address text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;

-- The blanket grants db/20-post/001 used to issue, which 004 replaces with an
-- allowlist. Present so the revoke has something to revoke.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;

-- The FORWARD-LOOKING half of the same grant, from db/00-bootstrap/001.
--
-- Absent until now, which made the probe at the end of db/20-post/012 pass
-- VACUOUSLY: it creates a table and checks that `authenticated` cannot write it,
-- and with no default-privileges entry to revoke there was nothing for that
-- check to catch. A green run proved only that the fixture had never granted
-- the thing being revoked.
--
-- That is the same defect 004 documents in the guard it replaced -- "it counts
-- ROWS, not POLICIES ... a security assertion whose result depends on how much
-- data happens to be present is not an assertion". Reproduced here so the probe
-- is testing the condition it was written for.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO service_role;

-- Real rows, so no assertion can pass merely because a table is empty -- which is
-- exactly how the vacuous check in the original 003 passed while balances were
-- readable.
INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
VALUES (424946351, 'victim', 5000, 5000), (999000111, 'attacker', 0, 0);
INSERT INTO games (game_number, status) VALUES (1, 'waiting');
INSERT INTO bank_options (bank_name, account_number, instructions) VALUES ('Telebirr', '0900000000', 'test');
