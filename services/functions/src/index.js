/**
 * Fanos Bingo functions service.
 *
 * The API surface that is not plain data access. Everything that IS plain data
 * access goes straight to PostgREST, where RLS enforces authorization on every
 * query — which is the point of this service issuing tokens rather than acting
 * on players' behalf.
 *
 * WHAT THIS DELIBERATELY IS NOT
 *
 * It is not a port of the 25 inherited Deno functions. Those were written for a
 * hosted Supabase project this fork never had; all 25 used the service-role key
 * and so bypassed every RLS policy, and all 25 trusted a caller identity taken
 * from the request body. Porting them would have carried both properties onto
 * infrastructure built specifically to avoid them.
 *
 * Nothing depends on the old behaviour — no deployment, no users — so this is
 * the cheapest moment this design will ever be changed. Routes are added here
 * deliberately, each one answering "why can RLS not do this?".
 *
 * Legitimate answers so far:
 *   - minting a token (the client cannot sign one)
 *   - signing a withdrawal with KMS (the key is reachable by exactly one role)
 *   - talking to Telegram or a chain RPC (secrets that must not reach a browser)
 *
 * WHAT STILL NEEDS BUILDING, and the auth each one requires. Recorded here
 * because the inherited Deno versions are not being ported, and the
 * requirements they taught us should not be lost with them.
 *
 *   POST /telegram/webhook
 *     Telegram calls this, not a browser, so initData does not apply. It must
 *     verify X-Telegram-Bot-Api-Secret-Token with verifyWebhookSecret() --
 *     STRICTLY, rejecting a missing header, because a forger simply omits it.
 *     The inherited version registered the webhook with no secret_token at all
 *     and checked nothing, so anyone who knew the URL could forge an update and
 *     impersonate any player to the bot. When registering, call setWebhook WITH
 *     secret_token, and re-register BEFORE deploying the check or the bot goes
 *     silent.
 *
 *   POST /withdrawals
 *     requireAuth, then sign with KMS. Never a private key from the database --
 *     that is how the original hot wallet leaked. task_functions is the only
 *     role permitted kms:Sign, which is what makes the CloudTrail alarm on
 *     signing by anything else a real signal rather than noise.
 *
 *   POST /deposits/confirm
 *     requireAuth. Credit only req.auth.uid, never an id from the body.
 *
 * Card selection, cell marking and game state are deliberately absent: those
 * are plain data access and belong in PostgREST under RLS.
 */

import express from 'express';
import pg from 'pg';
import fs from 'node:fs';
import { authenticateTelegram, authenticateTelegramWeb, requireAuth } from './auth.js';
import { verifyChainId, chainName } from './chain.js';
import { bodyParserErrorHandler } from './http-errors.js';
import { createRateLimiter, limitByPlayer } from './rate-limit.js';
import { createSnsAlertHandler } from './alerts.js';
import { createDeepReadyHandler } from './upstreams.js';
import { createOperatorNotifier } from './notify.js';
import { createTelegramWebhookHandler } from './telegram-webhook.js';
import { createSelectCardHandler } from './select-card.js';
import { createClaimBingoHandler } from './claim-bingo.js';
import { createDeselectCardHandler } from './deselect-card.js';
import {
  requireAdmin,
  requireSecondFactor,
  createTotpEnrollHandler,
  createTotpConfirmHandler,
  createAdminWhoamiHandler,
  createAdminBootstrapHandler,
  createEndGameHandler,
  createUpdateSettingHandler,
} from './admin.js';
import {
  createDepositClaimHandler,
  createListDepositsHandler,
  createApproveDepositHandler,
  createRejectDepositHandler,
} from './deposits.js';
import {
  createAvailableBalanceHandler,
  createRequestWithdrawalHandler,
  createListWithdrawalsHandler,
  createCompleteWithdrawalHandler,
  createRejectWithdrawalHandler,
} from './withdrawals.js';

const {
  PORT = '8080',
  ENVIRONMENT = 'dev',
  ALLOWED_ORIGIN,
  JWT_SECRET,
  TELEGRAM_BOT_TOKEN,
  TELEGRAM_WEBHOOK_SECRET,
  PGSSLROOTCERT,
  PGSSLMODE = 'verify-full',
  BSC_CHAIN_ID,
  BSC_RPC_PRIMARY,
  ADMIN_BOOTSTRAP_KEY,

  // Alerting. Both optional: with either absent the route still exists and
  // still verifies, it just has nowhere to forward to and says so in the log.
  // That is deliberate -- the subscription is created by Terraform, and a route
  // that 404s while SNS is subscribed to it would fail the subscription
  // confirmation and quietly disable the channel before anyone configured it.
  TELEGRAM_ALERT_CHAT_ID,
  ALERT_TOPIC_ARNS = '',
} = process.env;

/** Structured JSON, so CloudWatch Logs Insights can query the fields. */
function log(level, message, fields = {}) {
  process.stdout.write(
    JSON.stringify({
      ts: new Date().toISOString(),
      level,
      service: 'functions',
      env: ENVIRONMENT,
      message,
      ...fields,
    }) + '\n',
  );
}

// Fail at boot on missing configuration rather than at the first request.
//
// A service that starts without JWT_SECRET looks healthy, passes its health
// check, and rejects every login — an outage that presents as a client bug.
for (const [name, value] of Object.entries({ JWT_SECRET, TELEGRAM_BOT_TOKEN })) {
  if (!value) {
    log('error', `${name} is not set; refusing to start`, { missing: name });
    process.exit(1);
  }
}

// Same reasoning as the ticker: verify TLS to RDS against Amazon's committed CA
// bundle, and FAIL rather than silently downgrading. rejectUnauthorized:false
// encrypts the connection while verifying nothing, which for the process that
// reads player balances is not a trade worth making.
function buildSslConfig() {
  if (PGSSLMODE === 'disable') {
    log('warn', 'TLS disabled for the database connection');
    return false;
  }
  if (!PGSSLROOTCERT || !fs.existsSync(PGSSLROOTCERT)) {
    log('error', 'CA bundle missing; refusing to fall back to unverified TLS', {
      path: PGSSLROOTCERT ?? null,
    });
    process.exit(1);
  }
  return { ca: fs.readFileSync(PGSSLROOTCERT, 'utf8'), rejectUnauthorized: true };
}

const pool = new pg.Pool({
  ssl: buildSslConfig(),
  application_name: 'functions',
  max: 5,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
});

// Per-player limit on the one unauthenticated route.
//
// Ten per minute against a token that lives fifteen minutes: a real client
// authenticates once per session, so this is roughly thirty times what normal
// use needs, and still a hard ceiling on a script. Keyed on the VERIFIED
// telegram id rather than the source IP -- see src/rate-limit.js for why that
// distinction matters to this player base specifically.
//
// Overridable so the value is not buried in a build. It is not in SSM because
// changing it should not need a Terraform apply, and there is nothing secret
// about it.
const authLimiter = createRateLimiter({
  limit: Number(process.env.AUTH_RATE_LIMIT ?? 10),
  windowMs: Number(process.env.AUTH_RATE_WINDOW_MS ?? 60_000),
});

// Per-player limits on the AUTHENTICATED routes.
//
// The limiter above was the only one on this service, on the reasoning that
// /auth/telegram is the only unauthenticated route. That covers who may call and
// not what they may then do: a token lives fifteen minutes, and for those
// fifteen minutes every route below accepted work as fast as one client could
// send it, against a pool of five. See limitByPlayer() in src/rate-limit.js for
// why the exposure is resource exhaustion rather than privilege -- and why the
// blast radius of one caller doing it is everybody, including the ticker.
//
// TWO BUDGETS, because the routes differ by an order of magnitude in what
// legitimate use looks like:
//
//   play    joining, releasing and claiming, plus the available-balance read the
//           withdrawal form calls. Bursty and legitimate -- a player pressing
//           join on a lobby that is about to close, or a form re-reading a
//           balance -- so this is set well above anything a person produces and
//           only bites a script.
//
//   money   filing a deposit claim or requesting a withdrawal. Legitimate use is
//           once or twice a session, so six a minute is already thirty times
//           what a person does, and it is the tighter of the two because these
//           are the rows an operator has to read and act on by hand. A flood
//           here does not just cost connections, it costs the queue that
//           OldestPendingDepositMinutes alarms on.
//
// Overridable by environment variable rather than baked in, matching the auth
// limiter: changing a threshold should not need a Terraform apply, and there is
// nothing secret about the numbers.
//
// SINGLE PROCESS, IN MEMORY, and the same Stage 2 caveat applies as to the auth
// limiter above -- two instances would each permit the full budget. At one
// instance and one container it is exact.
const playLimiter = createRateLimiter({
  limit: Number(process.env.PLAY_RATE_LIMIT ?? 30),
  windowMs: Number(process.env.PLAY_RATE_WINDOW_MS ?? 60_000),
});

const moneyLimiter = createRateLimiter({
  limit: Number(process.env.MONEY_RATE_LIMIT ?? 6),
  windowMs: Number(process.env.MONEY_RATE_WINDOW_MS ?? 60_000),
});

const limitPlay = limitByPlayer({ limiter: playLimiter, name: 'play' });
const limitMoney = limitByPlayer({ limiter: moneyLimiter, name: 'money' });

// NOT APPLIED TO /admin/*, deliberately.
//
// An admin is a flag on a row, held by one or two people, and the work they do
// is a BACKLOG: approving fourteen deposits that accumulated overnight is
// exactly the burst any threshold worth having would block. Throttling that
// produces the failure the deposit alarm exists to catch -- a queue nobody can
// clear -- in the name of preventing a caller who already has the operator's
// token, at which point rate limiting is not the problem they present.
//
// The population is small enough that the honest control is the audit trail:
// db/20-post/006 records decided_by on every approval.

// Per-claim notification to the operator, reusing the chat the alarms already
// reach. modules/monitoring's four-hour pending-deposit alarm was explicitly
// written as "the backstop underneath a per-claim notification"; this is the
// notification, and the alarm stays -- a message nobody reads produces no alarm.
const notifier = createOperatorNotifier({
  botToken: TELEGRAM_BOT_TOKEN,
  chatId: TELEGRAM_ALERT_CHAT_ID,
  log,
});

if (!notifier.enabled) {
  log('warn', 'operator notifications disabled; TELEGRAM_ALERT_CHAT_ID is not set');
}

const app = express();
app.disable('x-powered-by');

// CORS locked to one origin.
//
// Every inherited function sent `Access-Control-Allow-Origin: *`, including the
// ones that move money — meaning any page on the internet could make a browser
// issue those requests. Falls back to "null" rather than "*" when unset, so a
// misconfiguration fails closed instead of silently restoring the old
// behaviour.
//
// REGISTERED BEFORE THE BODY PARSER, deliberately. A request whose body does not
// parse still needs these headers on its 400, or the browser reports an opaque
// CORS failure instead of the real reason. It also means an OPTIONS preflight is
// answered without parsing a body it does not have.
app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', ALLOWED_ORIGIN || 'null');
  res.set('Vary', 'Origin');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  // X-Admin-TOTP MUST BE LISTED, or the browser refuses to send it.
  //
  // A header the server reads is not a header the browser may transmit: the
  // preflight decides that, and anything absent from this list is stripped
  // before the request is made. The second-factor retry therefore never left
  // the browser, and Firefox reported it as
  //
  //   NetworkError when attempting to fetch resource
  //
  // which reads like the API is down rather than like a header being refused.
  // The server saw only the FIRST attempt -- logged as second_factor_rejected --
  // and nothing at all from the retry, so the logs looked like an operator
  // giving up rather than a client being blocked.
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Admin-TOTP');
  res.set('Access-Control-Max-Age', '600');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  return next();
});

app.use(express.json({ limit: '64kb' }));

// Answer a malformed body with 400 rather than letting it reach the generic
// handler as a 500.
//
// This is not tidiness. Three unparseable bodies used to take the entire service
// out of Caddy's rotation for ten seconds, for every player -- a 500 is what its
// passive health check counts. See services/functions/src/http-errors.js for the
// measurement and the full chain.
app.use(bodyParserErrorHandler(log));

app.use((req, _res, next) => {
  req.log = {
    warn: (f) => log('warn', 'request', { path: req.path, ...f }),
    error: (f) => log('error', 'request', { path: req.path, ...f }),
  };
  next();
});

// Touches no upstream, so it stays useful while diagnosing one that is down.
// Caddy health-checks this path.
app.get('/healthz', (_req, res) => res.status(200).send('ok'));

// Readiness is a different question from liveness: this one asks whether the
// database is reachable, and it is the one that should gate traffic.
app.get('/readyz', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.status(200).json({ ready: true });
  } catch (err) {
    log('warn', 'readiness check failed', { error: err.message });
    res.status(503).json({ ready: false });
  }
});

/**
 * GET /readyz/deep — is the whole ORIGIN serving?
 *
 * The one an external health check should watch. /healthz proves Caddy is up
 * (it answers that path itself, without touching an upstream) and /readyz proves
 * this service can reach the database. Neither says anything about postgrest or
 * realtime, and there are no ECS task-count alarms either -- so until this
 * existed, three of the five containers could stop with no alarm anywhere.
 *
 * See src/upstreams.js for why a non-200 from an upstream still counts as up,
 * and why this is one endpoint instead of three paid health checks.
 */
app.get('/readyz/deep', createDeepReadyHandler(pool));

/**
 * POST /auth/telegram  { initData }  ->  { token, expires_in, user }
 *
 * The only unauthenticated route, and necessarily so: it is where a caller
 * proves who they are. initData is signed by Telegram with a key derived from
 * the bot token, so a forged one fails the HMAC.
 */
app.post('/auth/telegram', async (req, res) => {
  const initData = req.body?.initData;

  if (typeof initData !== 'string' || !initData) {
    return res.status(400).json({ error: 'initData is required' });
  }

  try {
    const result = await authenticateTelegram(
      pool,
      initData,
      TELEGRAM_BOT_TOKEN,
      JWT_SECRET,
      authLimiter,
    );

    if (!result.ok) {
      // A 429 is answered differently from a 401, deliberately.
      //
      // Rate limiting is not an authentication failure and pretending otherwise
      // would be actively harmful: a real client told "authentication failed"
      // will re-verify and retry, adding load, while one told 429 with
      // Retry-After can wait. Nothing is leaked by admitting to a rate limit --
      // the caller already proved who they are to get here.
      if (result.status === 429) {
        log('warn', 'authentication rate limited', {
          telegram_user_id: result.telegramUserId,
          retry_after_seconds: result.retryAfterSeconds,
        });
        res.set('Retry-After', String(result.retryAfterSeconds));
        return res.status(429).json({
          error: 'too many authentication attempts',
          retry_after_seconds: result.retryAfterSeconds,
        });
      }

      // Logged with the reason, answered without it.
      log('warn', 'authentication rejected', { reason: result.reason });
      return res.status(result.status).json({ error: 'authentication failed' });
    }

    log('info', 'authenticated', { telegram_user_id: result.user.telegram_user_id });

    return res.json({
      token: result.token,
      expires_in: result.expires_in,
      user: result.user,
    });
  } catch (err) {
    log('error', 'authentication error', { error: err.message, stack: err.stack });
    return res.status(500).json({ error: 'internal error' });
  }
});

/**
 * POST /auth/telegram/web  { id, first_name, username, auth_date, hash, ... }
 *
 * The desktop door. Telegram's Login Widget signs the same identity for a web
 * page that initData signs for a Mini App, so an operator can work the deposit
 * and withdrawal queues from a keyboard instead of a phone.
 *
 * SAME IDENTITY, SAME SESSION. The token is indistinguishable from the Mini
 * App's -- same uuid in `sub`, same 15-minute life, same role -- so there is no
 * second kind of admin and no second thing for requireAdmin to understand. The
 * flag on the telegram_users row is what decides, exactly as it does in the app.
 *
 * DIFFERENT SIGNATURE, THOUGH. The widget's secret key is SHA256(bot_token)
 * where the Mini App's is HMAC_SHA256("WebAppData", bot_token). Separate
 * verifier, separate entry point; see services/functions/src/telegram-auth.js.
 *
 * REQUIRES BotFather /setdomain. Telegram refuses to render the widget on a
 * domain the bot has not claimed, which is what stops any site from collecting
 * logins for this bot.
 *
 * Shares the rate limiter with the Mini App route: the limit is per verified
 * telegram id, so it should not matter which door somebody came through.
 */
app.post('/auth/telegram/web', async (req, res) => {
  const payload = req.body;

  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return res.status(400).json({ error: 'login payload is required' });
  }

  try {
    const result = await authenticateTelegramWeb(
      pool,
      payload,
      TELEGRAM_BOT_TOKEN,
      JWT_SECRET,
      authLimiter,
    );

    if (!result.ok) {
      if (result.status === 429) {
        res.set('Retry-After', String(result.retryAfterSeconds));
        return res.status(429).json({
          error: 'too many authentication attempts',
          retry_after_seconds: result.retryAfterSeconds,
        });
      }

      log('warn', 'web authentication rejected', { reason: result.reason });
      return res.status(result.status).json({ error: 'authentication failed' });
    }

    log('info', 'authenticated on web', { telegram_user_id: result.user.telegram_user_id });

    return res.json({
      token: result.token,
      expires_in: result.expires_in,
      user: result.user,
    });
  } catch (err) {
    log('error', 'web authentication error', { error: err.message, stack: err.stack });
    return res.status(500).json({ error: 'internal error' });
  }
});

/**
 * GET /auth/whoami -> the identity the token proves.
 *
 * Exists so the auth path can be verified end to end without a money-moving
 * side effect. If this returns the right uuid through Caddy, then PostgREST
 * will read the same claims and RLS will resolve the same player.
 */
app.get('/auth/whoami', requireAuth(JWT_SECRET), (req, res) => {
  res.json({
    uid: req.auth.uid,
    telegram_user_id: req.auth.telegramUserId,
    role: req.auth.role,
  });
});

/**
 * POST /select-card  { gameId, cardNumber }  ->  select_card_atomic's result
 *
 * Joining a game. The first of the inherited routes to be built rather than
 * merely enumerated, and it is here rather than in PostgREST because it spends a
 * player's balance: select_card_atomic is SECURITY DEFINER and takes the
 * caller's identity as an unchecked parameter, so db/20-post/004 revoked EXECUTE
 * on it from anon and authenticated. This is its only caller.
 *
 * Until this existed the game was not playable. The loop ran, the board
 * rendered, the countdown ticked, and pressing join answered 404.
 *
 * See src/select-card.js for why neither the identity nor the CARD LAYOUT is
 * taken from the request body.
 */
app.post('/select-card', requireAuth(JWT_SECRET), limitPlay, createSelectCardHandler(pool));

/**
 * POST /claim-bingo  { playerId }  ->  atomic_claim_bingo's result
 *
 * Claiming a win. The other half of a playable game, and the other half of the
 * 404 pair with /select-card.
 *
 * Its authorization question differs: atomic_claim_bingo takes a PLAYER ROW id,
 * so the token saying who you are is not enough on its own -- the row must be
 * checked to be yours. See src/claim-bingo.js for what claiming on somebody
 * else's behalf would let you do to them.
 */
app.post('/claim-bingo', requireAuth(JWT_SECRET), limitPlay, createClaimBingoHandler(pool));

/**
 * POST /deselect-card  { playerId }  ->  release_card's result
 *
 * The inverse of /select-card, and the last of the inherited Deno names the
 * Lobby still called that had no implementation.
 *
 * It is a route rather than plain data access because deleting a players row
 * refunds money, and that is only legitimate while selection is still open --
 * a condition on the GAMES row, which an RLS policy on `players` cannot reach.
 * db/20-post/011 checks it under a row lock; db/20-post/008 revoked the DELETE
 * privilege that would let a client go around it.
 */
app.post('/deselect-card', requireAuth(JWT_SECRET), limitPlay, createDeselectCardHandler(pool));

/**
 * Admin.
 *
 * src/components/Admin.tsx validated its access key by POSTing to
 * /functions/v1/update-settings and treating anything that was not 401 as
 * success. That route answers 404, so ANY string logged you in. See
 * src/admin.js.
 *
 * An admin is now a flag on an identity Telegram already signed for, checked
 * server-side on every request. requireAdmin is chained AFTER requireAuth
 * because it needs the proven uid.
 */
app.get('/admin/whoami', requireAuth(JWT_SECRET), createAdminWhoamiHandler(pool));

// Promotes ONLY the caller, and ONLY while no admin exists -- so it disarms
// itself on first use and cannot grant admin to anybody else. Safe to leave
// deployed; see the header in src/admin.js for why all three properties matter.
app.post(
  '/admin/bootstrap',
  requireAuth(JWT_SECRET),
  createAdminBootstrapHandler(pool, ADMIN_BOOTSTRAP_KEY),
);

// The gate itself, proven to work before anything is put behind it.
app.get('/admin/ping', requireAuth(JWT_SECRET), requireAdmin(pool), (_req, res) =>
  res.json({ ok: true }),
);

/**
 * Enrolling a second factor.
 *
 * NOT behind requireSecondFactor, necessarily: an admin cannot present a code
 * from a secret they do not yet have. The enroll route refuses to overwrite a
 * CONFIRMED enrolment instead, which is what stops this being a single-factor
 * path to replacing the second factor.
 */
app.post('/admin/totp/enroll', requireAuth(JWT_SECRET), requireAdmin(pool), createTotpEnrollHandler(pool));
app.post('/admin/totp/confirm', requireAuth(JWT_SECRET), requireAdmin(pool), createTotpConfirmHandler(pool));

/**
 * Deposits.
 *
 * The player transfers to the house account themselves and files a claim; the
 * operator reads their own bank statement and decides. There is no automated
 * verification here on purpose -- see db/20-post/006 for why the inherited
 * SMS-matching pipeline is not used.
 *
 * Reading your OWN claims is deliberately not a route: 006 gives `authenticated`
 * a SELECT policy scoped to player_id = auth.uid(), so the Mini App fetches its
 * history straight from PostgREST.
 */
app.post('/deposits/claim', requireAuth(JWT_SECRET), limitMoney, createDepositClaimHandler(pool, notifier));

app.get(
  '/admin/deposits',
  requireAuth(JWT_SECRET),
  requireAdmin(pool),
  createListDepositsHandler(pool),
);

// SECOND FACTOR HERE, and on /admin/withdrawals/:id/complete, and nowhere else.
//
// These two are the operations that can invent money and discharge it.
// Everything else an admin does -- reading a queue, ending a game, changing a
// setting -- is reversible or bounded, and six digits per action is a real cost
// to somebody clearing an overnight backlog. See db/20-post/016.
app.post(
  '/admin/deposits/:id/approve',
  requireAuth(JWT_SECRET),
  requireAdmin(pool),
  requireSecondFactor(pool),
  createApproveDepositHandler(pool),
);

app.post(
  '/admin/deposits/:id/reject',
  requireAuth(JWT_SECRET),
  requireAdmin(pool),
  createRejectDepositHandler(pool),
);

/**
 * Bank withdrawals — the mirror of the deposit queue, and the half of the money
 * round trip that did not exist until now.
 *
 * db/20-post/007 had the correctness layer since it was written: the row lock,
 * the available-balance calculation, the freeze trigger and the unique payout
 * reference. What it did not have was any caller. Its three functions are
 * SECURITY DEFINER and take an identity as a parameter, so 007 revoked EXECUTE
 * from `authenticated` -- correctly -- and that left a player with no way to be
 * paid at all.
 *
 * Reading your OWN requests is deliberately not a route: 007 gives
 * `authenticated` a SELECT policy scoped through telegram_users, so the Mini App
 * fetches its history straight from PostgREST. Same division as deposits.
 *
 * /withdrawals/available is a route and not a client-side subtraction, because
 * the number the player is shown and the number request_bank_withdrawal()
 * enforces must come from one expression. See src/withdrawals.js.
 */
app.get(
  '/withdrawals/available',
  requireAuth(JWT_SECRET),
  limitPlay,
  createAvailableBalanceHandler(pool),
);

app.post(
  '/withdrawals/request',
  requireAuth(JWT_SECRET),
  limitMoney,
  createRequestWithdrawalHandler(pool, notifier),
);

app.get(
  '/admin/withdrawals',
  requireAuth(JWT_SECRET),
  requireAdmin(pool),
  createListWithdrawalsHandler(pool),
);

// Recorded AFTER the operator has actually sent the money. The payout reference
// is their own transfer's receipt, and 007's unique index on it is what stops
// one transfer being recorded as two payouts.
app.post(
  '/admin/withdrawals/:id/complete',
  requireAuth(JWT_SECRET),
  requireAdmin(pool),
  requireSecondFactor(pool),
  createCompleteWithdrawalHandler(pool),
);

app.post(
  '/admin/withdrawals/:id/reject',
  requireAuth(JWT_SECRET),
  requireAdmin(pool),
  createRejectWithdrawalHandler(pool),
);

/**
 * Ending a game. The operator's only write to `games`.
 *
 * db/20-post/008 revoked UPDATE on that table from the browser, because it was
 * what let any authenticated player set winner_ids and winner_prize_each and
 * have payout_winners() credit them. Admin.tsx's direct UPDATE went with it;
 * this replaces it.
 */
app.post(
  '/admin/games/:id/end',
  requireAuth(JWT_SECRET),
  requireAdmin(pool),
  createEndGameHandler(pool),
);

/**
 * Operator settings. NOT a port of update-settings: telegram_bot_token is not
 * writable, because db/20-post/003 redacted it from this table and it belongs
 * in SSM. The allowlist lives in admin_update_setting(), see db/20-post/013.
 */
app.post(
  '/admin/settings',
  requireAuth(JWT_SECRET),
  requireAdmin(pool),
  createUpdateSettingHandler(pool),
);

/**
 * POST /alerts/sns — CloudWatch alarms, forwarded to Telegram.
 *
 * UNAUTHENTICATED, and necessarily so: SNS cannot present a bearer token. The
 * Amazon signature is the authentication, the topic allowlist is the
 * authorization, and src/alerts.js does both before anything else happens.
 *
 * SMS was meant to be this channel. It was wired, applied, and does not
 * deliver -- AWS End User Messaging is not enabled on this account, so the send
 * path refuses before a phone number is even considered. Telegram is served
 * from here rather than a Lambda precisely because a Lambda is another AWS
 * service to be enrolled in, and "the service was not enabled and nothing said
 * so" is the failure being fixed.
 *
 * express.text() ON THIS ROUTE ONLY. SNS posts Content-Type: text/plain, which
 * the app-wide express.json() correctly ignores -- so without this the handler
 * receives an empty body and every alarm is dropped as unparseable. Registered
 * here rather than globally so no other route's parsing changes.
 */
app.post(
  '/alerts/sns',
  express.text({ type: '*/*', limit: '256kb' }),
  createSnsAlertHandler({
    botToken: TELEGRAM_BOT_TOKEN,
    chatId: TELEGRAM_ALERT_CHAT_ID,
    allowedTopicArns: ALERT_TOPIC_ARNS.split(',').map((s) => s.trim()),
  }),
);

/**
 * POST /telegram/webhook — Telegram's servers, not a browser.
 *
 * The last of the routes index.js has listed as "still needs building" since
 * this service was written. /start to the bot did nothing until now, which for
 * a Telegram-first product is the front door being locked.
 *
 * initData does not apply: Telegram is the caller, not a Mini App client. The
 * X-Telegram-Bot-Api-Secret-Token header is the entire authentication, checked
 * STRICTLY -- a missing header is refused, because a forger simply omits it.
 *
 * Registration is a separate, deliberate step: scripts/register-telegram-webhook.sh.
 * Until it runs, this route refuses everything, which is the safe direction.
 */
app.post(
  '/telegram/webhook',
  createTelegramWebhookHandler({
    pool,
    botToken: TELEGRAM_BOT_TOKEN,
    webhookSecret: TELEGRAM_WEBHOOK_SECRET,
    appUrl: ALLOWED_ORIGIN,
  }),
);

app.use((req, res) => res.status(404).json({ error: 'not found', path: req.path }));

// eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity
app.use((err, _req, res, _next) => {
  log('error', 'unhandled', { error: err.message, stack: err.stack });
  res.status(500).json({ error: 'internal error' });
});

/**
 * Confirm the RPC serves the chain this environment signs for.
 *
 * Not decoration. A signed EVM transaction commits to a chain id, so a
 * signature produced with 56 is a valid BSC MAINNET transaction wherever it was
 * made. Dev currently has three sources disagreeing -- the RPC and SSM say 97,
 * while settings.deposit_contract_chain_id says 56 -- and the day something
 * signs from the wrong one, the mistake is silent on testnet and expensive on
 * mainnet.
 *
 * Chain id comes from SSM, which Terraform sets per environment. The settings
 * table is application data and must never decide what a signature commits to.
 *
 * Checked at startup rather than per request: it is configuration, it does not
 * change while the process runs, and a service that cannot sign safely should
 * not be accepting traffic.
 */
async function checkChain() {
  if (!BSC_CHAIN_ID || !BSC_RPC_PRIMARY) {
    log('warn', 'chain verification skipped; signing routes must not be enabled', {
      bsc_chain_id: BSC_CHAIN_ID ?? null,
      rpc_configured: Boolean(BSC_RPC_PRIMARY),
    });
    return;
  }

  const expected = Number(BSC_CHAIN_ID);
  const result = await verifyChainId(BSC_RPC_PRIMARY, expected);

  if (result.ok) {
    log('info', 'chain verified', {
      chain_id: result.chainId,
      chain: chainName(result.chainId),
    });
    return;
  }

  if (result.unreachable) {
    // An outage is not a misconfiguration. Start, and say loudly that signing
    // is unverified -- rather than refusing to serve auth because an RPC blipped.
    log('error', 'RPC unreachable; chain is UNVERIFIED', { reason: result.reason });
    return;
  }

  // A genuine mismatch. Refuse to run: every signature this process produced
  // would commit to a chain nobody intended.
  log('error', 'CHAIN MISMATCH; refusing to start', {
    configured: expected,
    configured_name: chainName(expected),
    actual: result.actual,
    actual_name: chainName(result.actual),
    reason: result.reason,
  });
  process.exit(1);
}

await checkChain();

const server = app.listen(Number(PORT), () => {
  log('info', 'listening', {
    port: Number(PORT),
    allowed_origin: ALLOWED_ORIGIN || '(unset — CORS will deny browsers)',
  });
});

// ECS sends SIGTERM and kills after stopTimeout. Draining means in-flight
// requests finish rather than being cut mid-transaction.
async function shutdown(signal) {
  log('info', 'shutting down', { signal });
  server.close(async () => {
    try {
      await pool.end();
    } catch (err) {
      log('warn', 'error closing the pool', { error: err.message });
    }
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
