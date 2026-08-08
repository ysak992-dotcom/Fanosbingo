/**
 * Tests for the Telegram webhook route.
 *
 * The assertions that matter are about who is allowed to speak to it, and about
 * not letting Telegram retry forever:
 *
 *   - a MISSING secret header is refused. "Verify it if present" is no check at
 *     all, because a forger omits it -- which is exactly what the inherited Deno
 *     version did
 *   - a wrong secret is refused
 *   - an EXPRESS-shaped request works, which the inherited tests never checked:
 *     they build a Fetch `Request`, and req.headers.get() does not exist under
 *     Express. That shape mismatch would have thrown on Telegram's first call
 *   - once authenticated it always answers 200, because a non-2xx is redelivered
 *     with backoff and turns one bad message into a retry storm
 *
 * Run: node src/telegram-webhook.test.mjs
 */

import { createTelegramWebhookHandler } from './telegram-webhook.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

console.log('\ntelegram webhook');

const SECRET = 's3cret-token';

const mkRes = () => {
  const r = { code: null, body: null,
    status(c) { r.code = c; return r; },
    json(b) { r.body = b; return r; } };
  return r;
};

// EXPRESS shape, deliberately: req.get(), and req.headers as a plain object.
const mkReq = (headerValue, body = {}) => ({
  get: (n) => (n.toLowerCase() === 'x-telegram-bot-api-secret-token' ? headerValue ?? undefined : undefined),
  headers: headerValue ? { 'x-telegram-bot-api-secret-token': headerValue } : {},
  body,
  log: { warn() {}, error() {} },
});

const capture = () => {
  const sent = [];
  const impl = async (url, init) => {
    sent.push({ url, body: JSON.parse(init.body) });
    return { ok: true, status: 200, text: async () => '{}' };
  };
  impl.sent = sent;
  return impl;
};

const poolWith = (gameUrl) => ({
  query: async () => ({ rows: gameUrl ? [{ value: gameUrl }] : [] }),
});

const build = (f, pool = poolWith(null)) =>
  createTelegramWebhookHandler({
    pool, botToken: 'tok', webhookSecret: SECRET,
    appUrl: 'https://app.example.test', fetchImpl: f,
  });

// --- authentication -------------------------------------------------------
{
  const f = capture();
  const h = build(f);

  const noHeader = mkRes();
  await h(mkReq(undefined, { message: { text: '/start', chat: { id: 1 } } }), noHeader);
  check('a MISSING secret header is refused', noHeader.code === 401);
  check('and nothing is sent', f.sent.length === 0);

  const wrong = mkRes();
  await h(mkReq('not-the-secret', { message: { text: '/start', chat: { id: 1 } } }), wrong);
  check('a WRONG secret is refused', wrong.code === 401);
  check('without leaking the reason to the caller', wrong.body?.error === 'unauthorized');
}

// --- an unconfigured secret must refuse everything ------------------------
{
  const f = capture();
  const h = createTelegramWebhookHandler({
    pool: poolWith(null), botToken: 'tok', webhookSecret: undefined,
    appUrl: 'https://app.example.test', fetchImpl: f,
  });
  const res = mkRes();
  await h(mkReq('anything', { message: { text: '/start', chat: { id: 1 } } }), res);
  check('no configured secret means nothing authenticates', res.code === 401);
}

// --- /start, the whole point ----------------------------------------------
{
  const f = capture();
  const h = build(f);
  const res = mkRes();

  await h(mkReq(SECRET, { message: { text: '/start', chat: { id: 424946351 } } }), res);
  await sleep(10);

  check('a genuine /start answers 200', res.code === 200);
  check('and replies', f.sent.length === 1);
  check('to the chat that messaged', f.sent[0].body.chat_id === 424946351);
  check('with the app link', /https:\/\/app\.example\.test/.test(f.sent[0].body.text));
}

// --- the operator can move the link without a deploy ----------------------
{
  const f = capture();
  const h = build(f, poolWith('https://t.me/BingoNovaaBot?startapp'));
  await h(mkReq(SECRET, { message: { text: '/start', chat: { id: 7 } } }), mkRes());
  await sleep(10);
  check('game_url from settings wins over the fallback', /t\.me\/BingoNovaaBot/.test(f.sent[0].body.text));
}

// --- a database outage must not silence the bot ---------------------------
{
  const f = capture();
  const h = build(f, { query: async () => { throw new Error('db down'); } });
  await h(mkReq(SECRET, { message: { text: '/start', chat: { id: 8 } } }), mkRes());
  await sleep(10);
  check('a settings lookup failure still answers the player', f.sent.length === 1);
  check('using the fallback link', /app\.example\.test/.test(f.sent[0].body.text));
}

// --- always 200 once authenticated ---------------------------------------
//
// Telegram redelivers a non-2xx with backoff. One unhandled message must not
// become a retry storm.
{
  const boom = async () => { throw new Error('telegram unreachable'); };
  const h = build(boom);
  const res = mkRes();
  await h(mkReq(SECRET, { message: { text: '/start', chat: { id: 9 } } }), res);
  await sleep(20);
  check('a send failure still answered 200', res.code === 200);

  const odd = mkRes();
  await h(mkReq(SECRET, { edited_message: { text: 'hi' } }), odd);
  check('an update shape we do not handle is 200, not an error', odd.code === 200);

  const empty = mkRes();
  await h(mkReq(SECRET, {}), empty);
  check('an empty update is 200', empty.code === 200);
}

// --- the bot does not chatter ---------------------------------------------
{
  const f = capture();
  const h = build(f);
  await h(mkReq(SECRET, { message: { text: 'hello there', chat: { id: 1 } } }), mkRes());
  await sleep(10);
  check('plain chat is ignored, not answered', f.sent.length === 0);

  await h(mkReq(SECRET, { message: { text: '/unknown', chat: { id: 1 } } }), mkRes());
  await sleep(10);
  check('an unknown command is ignored too', f.sent.length === 0);

  // /start@BotName is what Telegram sends in groups.
  await h(mkReq(SECRET, { message: { text: '/start@BingoNovaaBot', chat: { id: 1 } } }), mkRes());
  await sleep(10);
  check('/start@BotName is recognised (this is what groups send)', f.sent.length === 1);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll webhook tests passed.');
process.exit(failures ? 1 : 0);
