/**
 * Fanos Bingo ticker.
 *
 * The game's heartbeat. Calls game_tick() once per second while holding a
 * PostgreSQL advisory lock, which guarantees exactly one caller across however
 * many instances are running.
 *
 * Why this exists at all:
 *
 *   Supabase drove the game with `cron.schedule_in_database('call-bingo-numbers',
 *   '4 seconds', ...)`. That six-field sub-minute syntax is a fork extension.
 *   Stock pg_cron on RDS has one-minute granularity and does not reject a
 *   sub-minute schedule — it simply never fires it. A game heartbeat that
 *   silently stops is the worst failure mode in this system.
 *
 *   Everything else the loop now owns (starting games, rolling countdowns,
 *   closing claim windows, creating the next game) was previously done by
 *   whichever browser happened to have the lobby open. The game literally did
 *   not progress if nobody was watching.
 *
 * Design notes:
 *
 *   - The advisory lock is session-scoped and held on a DEDICATED connection.
 *     If this process dies, the connection drops, PostgreSQL releases the lock,
 *     and a standby acquires it on its next attempt. No lease renewal, no
 *     expiry tuning, no split brain.
 *
 *   - A non-holder polls rather than exiting, so `instance_count = 2` at Stage 2
 *     gives fast failover with no further code changes.
 *
 *   - All game logic lives in game_tick(). This process is deliberately dumb:
 *     one round trip per tick, one transaction, correct locking in the database
 *     where it belongs.
 */

import fs from 'node:fs';
import pg from 'pg';
import { CloudWatchClient, PutMetricDataCommand } from '@aws-sdk/client-cloudwatch';

const {
  DATABASE_URL,
  TICK_INTERVAL_MS = '1000',
  CALL_INTERVAL_MS = '3500',
  CLAIM_WINDOW_MS = '1000',
  COUNTDOWN_SECONDS = '25',
  METRIC_NAMESPACE,
  ENVIRONMENT = 'dev',
  AWS_REGION = 'us-east-1',
  METRICS_ENABLED = 'true',
} = process.env;

// Arbitrary but fixed. Any process using this same key contends for the same
// lock, which is exactly what we want; it must never be reused for anything else.
const GAME_LOOP_LOCK_KEY = 728451923;

const TICK_MS = Number(TICK_INTERVAL_MS);
const metricsEnabled = METRICS_ENABLED === 'true' && Boolean(METRIC_NAMESPACE);

const cloudwatch = metricsEnabled
  ? new CloudWatchClient({ region: AWS_REGION })
  : null;

/** Structured JSON so CloudWatch Logs Insights can query these fields. */
function log(level, message, fields = {}) {
  process.stdout.write(
    JSON.stringify({
      ts: new Date().toISOString(),
      level,
      service: 'ticker',
      env: ENVIRONMENT,
      message,
      ...fields,
    }) + '\n'
  );
}

// Connection comes from the standard libpq variables (PGHOST, PGPORT, PGUSER,
// PGPASSWORD, PGDATABASE), which `pg` reads natively. ECS injects PGPASSWORD
// from SSM at container start.
//
// Deliberately not a single DATABASE_URL: assembling one in Terraform would put
// the password into Terraform state, which is plaintext JSON in S3. DATABASE_URL
// remains supported as an override for local runs.
if (!DATABASE_URL && !process.env.PGHOST) {
  log('error', 'No database connection configured: set PGHOST (and PGUSER/PGPASSWORD/PGDATABASE) or DATABASE_URL');
  process.exit(1);
}

/**
 * TLS to RDS.
 *
 * RDS presents a certificate signed by an Amazon CA that is not in Node's
 * default trust store, so an unconfigured connection fails with "self-signed
 * certificate in certificate chain".
 *
 * The tempting fix is rejectUnauthorized:false, which encrypts the connection
 * but verifies nothing — anything that can intercept the connection can then
 * read and rewrite every balance update. We verify against Amazon's published
 * CA bundle instead, baked into the image at build time.
 *
 * If the bundle is missing we FAIL rather than silently downgrading, because a
 * silent downgrade to unverified TLS is exactly the kind of thing that survives
 * unnoticed into production.
 */
function buildSslConfig() {
  const caPath = process.env.PGSSLROOTCERT;
  const mode = process.env.PGSSLMODE ?? 'require';

  if (mode === 'disable') {
    log('warn', 'TLS disabled for the database connection');
    return false;
  }

  if (!caPath) {
    log('error', 'PGSSLROOTCERT is not set. Refusing to connect without a CA to verify against.');
    process.exit(1);
  }

  if (!fs.existsSync(caPath)) {
    log('error', 'CA bundle not found; refusing to fall back to unverified TLS', { path: caPath });
    process.exit(1);
  }

  return {
    ca: fs.readFileSync(caPath, 'utf8'),
    rejectUnauthorized: true,
  };
}

const connectionConfig = {
  ...(DATABASE_URL ? { connectionString: DATABASE_URL } : {}),
  ssl: buildSslConfig(),
};

let shuttingDown = false;
let lockClient = null;
let pool = null;

/**
 * Take the game-loop lock.
 *
 * pg_try_advisory_lock returns immediately rather than queuing: a standby
 * should keep polling and stay ready, not block forever on a lock the holder
 * will keep for its entire lifetime.
 */
async function tryAcquireLock() {
  const client = new pg.Client({ ...connectionConfig, application_name: 'ticker-lock' });
  await client.connect();

  const { rows } = await client.query('SELECT pg_try_advisory_lock($1) AS acquired', [
    GAME_LOOP_LOCK_KEY,
  ]);

  if (rows[0].acquired) {
    lockClient = client;
    return true;
  }

  await client.end();
  return false;
}

/**
 * The manual money queues, on their own slower schedule.
 *
 * NOT folded into game_tick(). That runs once a second and is the game loop;
 * queue age moves three orders of magnitude slower, and coupling the two would
 * mean "is the game running" and "is anybody approving deposits" share a failure
 * path. They have different responders.
 *
 * WHY THIS EXISTS AT ALL: a player's activity panel showed a deposit pending for
 * a DAY against a zero play balance, while the deposit form promised "usually
 * within a few minutes". Nothing was broken -- the queue, the policy and the
 * route all worked. There was simply no signal that anything was in it.
 *
 * A metrics failure must never stop the game, so this is fire-and-forget in the
 * same way publishMetrics is.
 */
const QUEUE_HEALTH_INTERVAL_MS = Number(process.env.QUEUE_HEALTH_INTERVAL_MS ?? 60_000);
let lastQueueHealthAt = 0;

/**
 * Balance reconciliation, on a slower schedule again.
 *
 * FIVE MINUTES, not one, and the reason is cost rather than urgency.
 * reconcile_balances() groups the whole of balance_entries and joins it to
 * telegram_users, so it is O(entries) -- trivial at this size and not something
 * to run every second forever. Drift is also not a race: if a balance has moved
 * without being journalled, it will still have done so in five minutes, and
 * nothing about answering sooner changes the response.
 *
 * WHAT THE METRIC IS FOR. db/20-post/019 makes the journal the primary record of
 * every balance movement. A journal nobody compares against the balances is a
 * table that grows; the comparison is the control, and publishing it is what
 * turns "we could reconcile" into "we would be told". drifted > 0 means either a
 * balance moved without an entry or an entry was altered, and both are things to
 * find out about from an alarm rather than from a player.
 */
const RECONCILE_INTERVAL_MS = Number(process.env.RECONCILE_INTERVAL_MS ?? 300_000);
let lastReconcileAt = 0;

async function publishBalanceDrift(client) {
  if (!cloudwatch) return;

  const now = Date.now();
  if (now - lastReconcileAt < RECONCILE_INTERVAL_MS) return;
  lastReconcileAt = now;

  try {
    const { rows } = await client.query('SELECT reconcile_balances() AS r');
    const r = rows[0]?.r;
    if (!r) return;

    const drifted = Number(r.drifted ?? 0);

    // Logged, not just published, and at error rather than info: a CloudWatch
    // metric says how many, while the log says WHICH -- and the accounts are
    // what somebody actually needs when they start looking.
    if (drifted > 0) {
      log('error', 'balance ledger drift detected', {
        drifted,
        drift_total: Number(r.drift_total ?? 0),
        accounts: r.worst,
      });
    }

    const dims = [{ Name: 'Environment', Value: ENVIRONMENT }];

    await cloudwatch.send(
      new PutMetricDataCommand({
        Namespace: METRIC_NAMESPACE,
        MetricData: [
          {
            // THE alarm metric of this pair. Zero is the invariant; any other
            // value means the ledger and the balances disagree.
            MetricName: 'BalanceDriftAccounts',
            Value: drifted,
            Unit: 'Count',
            Dimensions: dims,
          },
          {
            // Size, not just existence. One account out by 1 and one out by
            // 40000 are different incidents.
            MetricName: 'BalanceDriftTotal',
            Value: Number(r.drift_total ?? 0),
            Unit: 'Count',
            Dimensions: dims,
          },
        ],
      })
    );
  } catch (error) {
    log('warn', 'Failed to publish balance drift', { error: error.message });
  }
}

async function publishQueueHealth(client) {
  if (!cloudwatch) return;

  const now = Date.now();
  if (now - lastQueueHealthAt < QUEUE_HEALTH_INTERVAL_MS) return;
  lastQueueHealthAt = now;

  try {
    const { rows } = await client.query('SELECT queue_health() AS q');
    const q = rows[0]?.q;
    if (!q) return;

    const dims = [{ Name: 'Environment', Value: ENVIRONMENT }];

    await cloudwatch.send(
      new PutMetricDataCommand({
        Namespace: METRIC_NAMESPACE,
        MetricData: [
          {
            // THE alarm metric of the pair. A deposit sitting unapproved is a
            // player who cannot join a game, and who was told "a few minutes".
            MetricName: 'OldestPendingDepositMinutes',
            Value: Number(q.oldest_pending_deposit_minutes ?? 0),
            Unit: 'Count',
            Dimensions: dims,
          },
          {
            MetricName: 'OldestPendingWithdrawalMinutes',
            Value: Number(q.oldest_pending_withdrawal_minutes ?? 0),
            Unit: 'Count',
            Dimensions: dims,
          },
          {
            // Counts answer a different question from ages. One old claim is
            // somebody forgotten; forty recent ones is a queue nobody is working.
            MetricName: 'PendingDeposits',
            Value: Number(q.pending_deposits ?? 0),
            Unit: 'Count',
            Dimensions: dims,
          },
          {
            MetricName: 'PendingWithdrawals',
            Value: Number(q.pending_withdrawals ?? 0),
            Unit: 'Count',
            Dimensions: dims,
          },
          {
            // The operator's float requirement. If this exceeds what is in the
            // house account, the queue cannot be cleared however promptly
            // somebody looks at it.
            MetricName: 'PendingWithdrawalTotal',
            Value: Number(q.pending_withdrawal_total ?? 0),
            Unit: 'Count',
            Dimensions: dims,
          },
        ],
      })
    );
  } catch (error) {
    log('warn', 'Failed to publish queue health', { error: error.message });
  }
}

async function publishMetrics(result, tickDurationMs) {
  if (!cloudwatch) return;

  const dims = [{ Name: 'Environment', Value: ENVIRONMENT }];

  try {
    await cloudwatch.send(
      new PutMetricDataCommand({
        Namespace: METRIC_NAMESPACE,
        MetricData: [
          {
            // THE alarm metric. If this climbs, the game is frozen and players
            // are staring at a board that stopped moving.
            MetricName: 'SecondsSinceLastNumberCalled',
            Value: (result.oldest_call_age_ms ?? 0) / 1000,
            Unit: 'Seconds',
            Dimensions: dims,
          },
          {
            MetricName: 'ActiveGames',
            Value: result.active_games ?? 0,
            Unit: 'Count',
            Dimensions: dims,
          },
          {
            MetricName: 'TickDuration',
            Value: tickDurationMs,
            Unit: 'Milliseconds',
            Dimensions: dims,
          },
        ],
      })
    );
  } catch (error) {
    // Never let a metrics failure stop the game.
    log('warn', 'Failed to publish metrics', { error: error.message });
  }
}

async function tick() {
  const started = Date.now();

  const { rows } = await pool.query(
    'SELECT game_tick($1, $2, $3) AS result',
    [Number(CALL_INTERVAL_MS), Number(CLAIM_WINDOW_MS), Number(COUNTDOWN_SECONDS)]
  );

  const result = rows[0].result;
  const duration = Date.now() - started;

  // Log only ticks where something happened. At one tick per second, logging
  // every no-op would be ~86k lines a day of nothing, and CloudWatch log
  // ingestion is a real cost line at this budget.
  const didSomething =
    result.numbers_called > 0 ||
    result.games_started > 0 ||
    result.games_finished > 0 ||
    result.claims_closed > 0 ||
    result.waiting_game_created;

  if (didSomething) {
    log('info', 'tick', { ...result, duration_ms: duration });
  }

  if (duration > TICK_MS) {
    // The loop cannot keep its cadence. At this point number calls drift and
    // players notice.
    log('warn', 'Tick exceeded its interval', {
      duration_ms: duration,
      interval_ms: TICK_MS,
    });
  }

  await publishMetrics(result, duration);

  // Money queues, on their own interval. Rate-limited inside rather than by a
  // second timer: one scheduler, and it cannot drift out of phase with the tick
  // or keep the event loop alive past a SIGTERM the way an unref'd interval
  // would. `pool` rather than the lock connection -- this is an ordinary read
  // and must not share the session that holds the advisory lock.
  await publishQueueHealth(pool);

  // Ledger reconciliation, on a slower interval again, for the same reasons.
  await publishBalanceDrift(pool);
}

/**
 * Fixed-delay rather than setInterval: setInterval queues overlapping
 * executions if a tick ever runs long, which for a game loop means two
 * concurrent game_tick() calls.
 */
async function runLoop() {
  while (!shuttingDown) {
    const started = Date.now();

    try {
      await tick();
    } catch (error) {
      log('error', 'Tick failed', { error: error.message, stack: error.stack });
      // Deliberately keep going. A transient database blip should not take the
      // game down; the SecondsSinceLastNumberCalled alarm covers a real outage.
    }

    const elapsed = Date.now() - started;
    const wait = Math.max(0, TICK_MS - elapsed);
    await new Promise((resolve) => setTimeout(resolve, wait));
  }
}

async function main() {
  log('info', 'Starting', {
    tick_interval_ms: TICK_MS,
    call_interval_ms: Number(CALL_INTERVAL_MS),
    metrics: metricsEnabled,
  });

  pool = new pg.Pool({
    ...connectionConfig,
    application_name: 'ticker',
    max: 2,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
  });

  // Fail fast on a bad connection string rather than looping on errors.
  await pool.query('SELECT 1');

  while (!shuttingDown) {
    if (await tryAcquireLock()) {
      log('info', 'Acquired game-loop lock; this instance is the caller');
      break;
    }
    log('info', 'Another instance holds the game-loop lock; standing by');
    await new Promise((resolve) => setTimeout(resolve, 5000));
  }

  if (!shuttingDown) await runLoop();
}

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log('info', 'Shutting down', { signal });

  // Release explicitly so a standby takes over in milliseconds rather than
  // waiting for the server to notice a dropped connection.
  try {
    if (lockClient) {
      await lockClient.query('SELECT pg_advisory_unlock($1)', [GAME_LOOP_LOCK_KEY]);
      await lockClient.end();
    }
    if (pool) await pool.end();
  } catch (error) {
    log('warn', 'Error during shutdown', { error: error.message });
  }

  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

main().catch((error) => {
  log('error', 'Fatal', { error: error.message, stack: error.stack });
  process.exit(1);
});
