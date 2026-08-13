/*
  # RDS bootstrap: Supabase compatibility layer
  #
  # Runs BEFORE the 128 Supabase migrations. Without it every one of them fails,
  # because Supabase provisions a lot implicitly that stock PostgreSQL does not.
  #
  # An audit of the migration set found the dependency surface is small:
  #
  #   auth.uid()                   9 call sites, in RLS policies
  #   anon / authenticated /
  #     service_role               roles named by 47 RLS policies
  #   pg_cron                      1 CREATE EXTENSION
  #   supabase_realtime            2 ALTER PUBLICATION
  #
  # gen_random_uuid() is used in 11 files but is native to PostgreSQL 13+, so no
  # pgcrypto is required. No crypt/digest/hmac usage exists.
  #
  # IDEMPOTENT: safe to re-run. Roles are cluster-wide, so every CREATE ROLE is
  # guarded.
  #
  # Reads the authenticator password from the DB_AUTHENTICATOR_PASSWORD
  # environment variable via \getenv, rather than a -v flag, so the password
  # never appears in the process list on the runner.
*/

\getenv authenticator_password DB_AUTHENTICATOR_PASSWORD
\getenv app_password DB_APP_PASSWORD

-- Fail early and clearly rather than creating a role with a literal
-- ":'authenticator_password'" as its password.
\if :{?authenticator_password}
\else
\echo 'ERROR: DB_AUTHENTICATOR_PASSWORD is not set in the environment.'
\quit 1
\endif

\if :{?app_password}
\else
\echo 'ERROR: DB_APP_PASSWORD is not set in the environment.'
\quit 1
\endif

-- ---------------------------------------------------------------------------
-- 1. Roles
--
-- PostgREST connects as `authenticator`, which is deliberately near-powerless,
-- then SET ROLEs to anon or authenticated based on the JWT. That indirection is
-- what makes a leaked connection string far less damaging than a leaked
-- superuser credential.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;

  -- BYPASSRLS mirrors Supabase's service_role. Only privileged server-side code
  -- ever assumes it; it is never reachable from a client JWT.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;

END $$;

-- `authenticator` is handled outside the DO block above, because psql does NOT
-- interpolate :'variables' inside dollar-quoted strings -- $$...$$ is an opaque
-- string literal to psql, so the reference survives verbatim into the server
-- and fails with "syntax error at or near :". Building the statement with
-- format() and running it through \gexec keeps the substitution client-side,
-- where it works.
--
-- %L quotes the password as a literal, so a password containing quotes cannot
-- break out of the statement.
SELECT format('CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD %L', :'authenticator_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator')
\gexec

-- Applied unconditionally so re-running rotates the password to whatever is
-- currently in SSM.
SELECT format('ALTER ROLE authenticator WITH LOGIN NOINHERIT PASSWORD %L', :'authenticator_password')
\gexec

GRANT anon, authenticated, service_role TO authenticator;

-- `app_service` is the login role the ticker and functions containers use. It
-- INHERITs service_role, unlike authenticator, because those containers are
-- trusted server-side code that needs privileged access from the moment they
-- connect -- there is no per-request role switch to perform.
--
-- Kept separate from `authenticator` so a leaked PostgREST connection string
-- cannot drive the game loop or move money.
SELECT format('CREATE ROLE app_service LOGIN INHERIT PASSWORD %L', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_service')
\gexec

SELECT format('ALTER ROLE app_service WITH LOGIN INHERIT PASSWORD %L', :'app_password')
\gexec

GRANT service_role TO app_service;

-- AND THE ATTRIBUTE, SEPARATELY, because membership does not carry it.
--
-- BYPASSRLS is a role ATTRIBUTE, not a privilege. `GRANT service_role TO
-- app_service` with INHERIT passes on service_role's table privileges and makes
-- app_service match `TO service_role` POLICIES -- but it does not pass on
-- BYPASSRLS, SUPERUSER, CREATEDB or any other attribute. Those follow the role
-- you actually are, not the roles you are a member of.
--
-- The gap was invisible for months because it only bites on a table with no
-- service_role policy. telegram_users has two, so every query the ticker and the
-- functions service made against it worked, and the comment above claiming
-- app_service "needs privileged access from the moment it connects" read as true.
--
-- bank_options has only an `authenticated` policy. So when the deposit route
-- looked up which house account a claim named, it matched no policy, read zero
-- rows, and answered "unknown or inactive bank option" for an account that was
-- plainly there. Diagnosed by comparing pg_roles.rolbypassrls against
-- pg_has_role() -- the membership was true and the attribute was false.
--
-- Fixed here rather than by adding a service_role policy to bank_options,
-- because the policy route has to be repeated for every table anyone ever adds
-- and this failure is silent: a missing policy reads as an empty table, not as
-- an error. The stated intent has always been that these containers are trusted
-- server-side code.
--
-- THE TRADE, stated: a leaked app_service password plus network access to RDS
-- reads everything. RDS has no public endpoint and the password lives in SSM,
-- and this was already effectively true through the service_role policies on
-- telegram_users -- but it is now true uniformly rather than by accident.
ALTER ROLE app_service BYPASSRLS;

-- ---------------------------------------------------------------------------
-- 2. auth schema shim
--
-- PostgREST puts the verified JWT payload into the `request.jwt.claims` GUC for
-- the duration of each request. These functions read it, which is exactly how
-- Supabase implements them — so the 9 RLS policies referencing auth.uid() work
-- unchanged against self-hosted PostgREST.
--
-- The `true` second argument to current_setting suppresses the error when the
-- GUC is unset (background jobs, psql sessions), returning NULL instead. RLS
-- policies then simply match nothing, which is the correct failure direction.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- Returns the subject claim as uuid. Call sites compare it against
-- telegram_users.id, which is uuid, so the cast is required.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(
    current_setting('request.jwt.claims', true)::jsonb ->> 'sub',
    ''
  )::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(
    current_setting('request.jwt.claims', true)::jsonb ->> 'role',
    ''
  )::text
$$;

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claims', true), ''),
    '{}'
  )::jsonb
$$;

-- EXECUTE granted EXPLICITLY, not inherited.
--
-- These three used to rely on PostgreSQL's built-in "new functions are
-- executable by PUBLIC" default. db/20-post/004 removes that default, because
-- it is what made six money-moving functions in `public` callable by an
-- unauthenticated HTTP request without anyone ever writing a GRANT.
--
-- Removing it makes this dependency load-bearing in a way that would only
-- surface on a FRESH database -- a restore drill, or the first prod apply --
-- where a function added to this schema after 004 has run once would be created
-- without PUBLIC execute. Every RLS policy in the system calls auth.uid(), so
-- the symptom would be "permission denied for function uid" on every query, at
-- the least convenient possible moment.
GRANT EXECUTE ON FUNCTION auth.uid(), auth.role(), auth.jwt()
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Extensions
--
-- pg_cron must be created in the database named by the cron.database_name
-- parameter, which Terraform sets to this database. Creating it elsewhere
-- appears to succeed and then never runs anything.
--
-- NOTE: pg_cron on RDS has ONE-MINUTE granularity. The 4-second game loop that
-- Supabase ran here is NOT portable and is deliberately not recreated; see
-- db/20-post. The ticker container owns that job now.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- pgcrypto, for gen_random_bytes() in 20251215115459_add_sms_forwarding_system.
--
-- Easy to miss when auditing: gen_random_UUID() is native to PostgreSQL 13+ and
-- needs nothing, but gen_random_BYTES() is pgcrypto-only. Supabase enables
-- pgcrypto by default, so the migration never had to ask for it.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- 4. Realtime publication
--
-- Two migrations run `ALTER PUBLICATION supabase_realtime ADD TABLE ...`, which
-- fails outright if the publication does not already exist. Supabase creates it
-- for you; here we must.
--
-- Created empty. The migrations add `games` and `players` themselves.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4b. Realtime's own schema
--
-- The supabase/realtime container runs its Ecto migrations against a schema set
-- by DB_AFTER_CONNECT_QUERY (`SET search_path TO _realtime`). If that schema
-- does not already exist the container dies on boot with:
--
--   (Postgrex.Error) ERROR 3F000 (invalid_schema_name)
--   no schema has been selected to create in
--
-- It cannot create the schema itself, because the failing statement IS the
-- creation of its migration-tracking table. Verified by running the real image
-- against a local PostgreSQL.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS _realtime;

-- Ownership, not just USAGE.
--
-- Creating the schema is necessary but NOT sufficient: Realtime connects as
-- app_service and must CREATE TABLE inside it. Without that privilege the
-- failure looks identical to the schema being absent --
--
--   (Postgrex.Error) ERROR 3F000 (invalid_schema_name)
--   no schema has been selected to create in
--
-- because `SET search_path TO _realtime` succeeds, but the search path then
-- contains no schema the role may create in. Easy to misdiagnose as "the
-- CREATE SCHEMA did not run".
--
-- Ownership rather than a grant list, so Realtime's future migrations can also
-- alter and drop what they created.
ALTER SCHEMA _realtime OWNER TO app_service;
GRANT ALL ON SCHEMA _realtime TO app_service;

-- Realtime consumes a logical replication slot, which requires the REPLICATION
-- attribute. On RDS that is granted through the rds_replication role, which
-- does not exist on stock PostgreSQL -- hence the guard, so this file still
-- applies cleanly to a local container used for testing.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_replication') THEN
    GRANT rds_replication TO app_service;
    RAISE NOTICE 'Granted rds_replication to app_service';
  ELSE
    RAISE NOTICE 'rds_replication not present (not RDS); skipping replication grant';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Schema privileges and default grants
--
-- RLS decides WHICH ROWS a role may touch, but only after table-level
-- privileges let it touch the table at all. Supabase sets these defaults behind
-- the scenes; their absence presents as "permission denied for table games"
-- from PostgREST even though the RLS policies look correct.
--
-- ALTER DEFAULT PRIVILEGES applies to objects created later by the migration
-- runner's role, which is why this must run BEFORE the 128 migrations.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO anon;

-- SELECT ONLY, since 2026-08-13. This granted INSERT, UPDATE and DELETE too.
--
-- db/20-post/012 exists to take those back, and it works -- but it runs LAST,
-- after all 122 migration files. This runs FIRST, by necessity: ALTER DEFAULT
-- PRIVILEGES only affects tables created afterwards. So every table created in
-- between was client-writable, for the whole duration of a migration run --
-- measured at 190 seconds against prod -- while the API stayed live.
--
-- That window was the only thing the blanket grant ever bought. Nothing needs
-- it: every client write goes through a SECURITY DEFINER function called by
-- app_service, which is what 004 and 012 established and what the withdrawal
-- and deposit routes were rewritten to use.
--
-- 012 KEEPS ITS REVOKE. It is now a no-op against a correct bootstrap, which is
-- exactly what a belt-and-braces control should be -- and its probe still
-- proves a newly created table is unwritable, which is the assertion that would
-- catch this being reintroduced.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
